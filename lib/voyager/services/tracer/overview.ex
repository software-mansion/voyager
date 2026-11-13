defmodule Voyager.Services.Tracer.Overview do
  @moduledoc """
  Pairs a session's control entries into runs and buckets its trace timestamps
  across those runs, with `nil` markers between runs.
  """

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Session

  @bucket_count 40

  @type run :: %{
          index: pos_integer(),
          seq: non_neg_integer(),
          next_seq: non_neg_integer() | nil,
          origin: Tracer.origin(),
          started_at: DateTime.t(),
          stopped_at: DateTime.t() | nil,
          duration_ms: non_neg_integer(),
          traces: non_neg_integer(),
          dropped: non_neg_integer(),
          reason: :running | Tracer.stop_reason(),
          config: Config.t() | nil,
          previous_config: Config.t() | nil
        }

  @spec bucket_count() :: pos_integer()
  def bucket_count, do: @bucket_count

  @doc """
  Builds the chronological list of runs from newest-first control `entries` and the
  current `session`. `now` bounds the elapsed duration of a still-running run.
  """
  @spec runs([Entry.t()], Session.t(), DateTime.t()) :: [run()]
  def runs(controls, %Session{} = session, now \\ DateTime.utc_now()) do
    ordered = Enum.sort_by(controls, & &1.seq, :asc)
    starts = Enum.filter(ordered, &(&1.kind == :started))

    starts
    |> Enum.with_index(1)
    |> Enum.scan(nil, fn {start, index}, prev_run ->
      next_start = Enum.at(starts, index)
      next_seq = next_start && next_start.seq
      stop = find_stop(ordered, start.seq, next_seq)
      config = config_at(ordered, start.seq) || session.config
      prev_config = prev_run && prev_run.config

      build_run(index, start, next_seq, stop, config, prev_config, session, now)
    end)
  end

  @doc """
  Buckets per-run `{run_index, at_us}` timestamps into up to `total_buckets` integer
  counts, inserting `nil` dividers between runs. Returns `[]` when there are no traces.
  """
  @spec activity([run()], [{pos_integer(), integer()}], pos_integer()) ::
          [non_neg_integer() | nil]
  def activity(runs, run_timestamps, total_buckets \\ @bucket_count)
  def activity([], _run_timestamps, _total_buckets), do: []
  def activity(_runs, [], _total_buckets), do: []

  def activity(runs, run_timestamps, total_buckets) do
    grouped = Enum.group_by(run_timestamps, &elem(&1, 0), &elem(&1, 1))
    allocations = allocate_buckets(runs, total_buckets)

    runs
    |> Enum.zip(allocations)
    |> Enum.map(fn {run, count} ->
      bucket_run(run, Map.get(grouped, run.index, []), count)
    end)
    |> Enum.intersperse([nil])
    |> List.flatten()
  end

  @doc "Pairs each `:trace` entry with the `index` of the run its `seq` falls into."
  @spec trace_timestamps([run()], [Entry.t()]) :: [{pos_integer(), integer()}]
  def trace_timestamps([], _entries), do: []

  def trace_timestamps(runs, entries) do
    for %{kind: :trace, seq: seq, at: at} <- entries,
        run = Enum.find(runs, &in_run?(&1, seq)),
        not is_nil(run),
        do: {run.index, at}
  end

  defp in_run?(%{seq: seq, next_seq: nil}, entry_seq), do: entry_seq > seq

  defp in_run?(%{seq: seq, next_seq: next_seq}, entry_seq),
    do: entry_seq > seq and entry_seq < next_seq

  defp find_stop(ordered, start_seq, nil) do
    Enum.find(ordered, &(&1.kind == :stopped and &1.seq > start_seq))
  end

  defp find_stop(ordered, start_seq, next_seq) do
    Enum.find(ordered, &(&1.kind == :stopped and &1.seq > start_seq and &1.seq < next_seq))
  end

  defp config_at(ordered, start_seq) do
    ordered
    |> Enum.take_while(&(&1.seq < start_seq))
    |> Enum.reverse()
    |> Enum.find_value(&(&1.kind == :configured && &1.config))
  end

  defp build_run(index, start, next_seq, stop, config, prev_config, session, now) do
    started_at = DateTime.from_unix!(start.at, :microsecond)

    {stopped_at, reason, traces, dropped} =
      run_outcome(stop, is_nil(next_seq), started_at, session)

    duration_ms = max(DateTime.diff(stopped_at || now, started_at, :millisecond), 0)

    %{
      index: index,
      seq: start.seq,
      next_seq: next_seq,
      origin: start.origin,
      started_at: started_at,
      stopped_at: stopped_at,
      duration_ms: duration_ms,
      traces: traces,
      dropped: dropped,
      reason: reason,
      config: config,
      previous_config: if(prev_config && prev_config != config, do: prev_config)
    }
  end

  defp run_outcome(%{} = stop, _last?, _started_at, _session) do
    {DateTime.from_unix!(stop.at, :microsecond), stop.reason, stop.traces, stop.dropped}
  end

  defp run_outcome(nil, true, _started_at, %Session{status: :running} = session) do
    {nil, :running, max(session.traces - session.run_traces_before, 0), session.dropped}
  end

  defp run_outcome(nil, true, _started_at, %Session{} = session) do
    {session.stopped_at, session.stop_reason || :interrupted,
     max(session.traces - session.run_traces_before, 0), session.dropped}
  end

  defp run_outcome(nil, false, started_at, _session), do: {started_at, :interrupted, 0, 0}

  defp allocate_buckets(runs, total_buckets) do
    run_count = length(runs)
    budget = max(total_buckets, run_count)
    extra = budget - run_count
    total_ms = runs |> Enum.map(&max(&1.duration_ms, 1)) |> Enum.sum()

    raw =
      Enum.map(runs, fn run ->
        exact = extra * max(run.duration_ms, 1) / total_ms
        {1 + trunc(exact), exact - trunc(exact)}
      end)

    assigned = raw |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    leftover = budget - assigned

    top_indices =
      raw
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_base, frac}, idx} -> {-frac, idx} end)
      |> Enum.take(leftover)
      |> MapSet.new(&elem(&1, 1))

    raw
    |> Enum.with_index()
    |> Enum.map(fn {{base, _frac}, idx} ->
      if MapSet.member?(top_indices, idx), do: base + 1, else: base
    end)
  end

  defp bucket_run(_run, [], count), do: List.duplicate(0, count)
  defp bucket_run(_run, ats, 1), do: [length(ats)]

  defp bucket_run(run, ats, count) do
    start_us = DateTime.to_unix(run.started_at, :microsecond)
    min_at = Enum.min([start_us | ats])

    stop_us =
      if run.stopped_at,
        do: DateTime.to_unix(run.stopped_at, :microsecond),
        else: Enum.max(ats)

    max_at = Enum.max([stop_us | ats])
    span = max(max_at - min_at, 1)

    counts =
      Enum.reduce(ats, %{}, fn at, acc ->
        idx = min(div((at - min_at) * count, span), count - 1)
        Map.update(acc, idx, 1, &(&1 + 1))
      end)

    for idx <- 0..(count - 1), do: Map.get(counts, idx, 0)
  end
end
