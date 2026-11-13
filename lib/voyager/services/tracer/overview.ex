defmodule Voyager.Services.Tracer.Overview do
  @moduledoc """
  Pairs a session's control entries into runs and buckets its trace timestamps
  into fixed-width time slices.
  """

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Session

  @max_buckets 60
  @live_bucket_ms 1_000
  @bucket_ladder_ms [
    1_000,
    2_000,
    5_000,
    10_000,
    15_000,
    30_000,
    60_000,
    120_000,
    300_000,
    600_000,
    900_000,
    1_800_000,
    3_600_000,
    7_200_000,
    21_600_000,
    43_200_000,
    86_400_000
  ]

  @type segment :: %{
          start_us: integer(),
          counts: [non_neg_integer()],
          gap_before_ms: non_neg_integer() | nil
        }

  @type activity :: %{
          bucket_ms: pos_integer(),
          live?: boolean(),
          segments: [segment()],
          end_us: integer()
        }

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
  Counts per-run `{run_index, at_us}` timestamps in fixed-width time slices. A running
  session shows the last `@max_buckets` seconds up to `now`; otherwise each run gets its
  own segment, with the time skipped since the previous run in `gap_before_ms`.
  Slices are aligned to the clock or the run start, so a trace never moves to another
  slice as more arrive. Returns `nil` when there is nothing to draw.
  """
  @spec activity([run()], [{pos_integer(), integer()}], DateTime.t()) :: activity() | nil
  def activity(runs, run_timestamps, now \\ DateTime.utc_now())
  def activity([], _run_timestamps, _now), do: nil

  def activity(runs, run_timestamps, now) do
    if List.last(runs).reason == :running,
      do: live_activity(run_timestamps, now),
      else: full_activity(runs, run_timestamps)
  end

  defp live_activity(run_timestamps, now) do
    bucket_us = @live_bucket_ms * 1_000
    last = div(DateTime.to_unix(now, :microsecond), bucket_us)
    first = last - @max_buckets + 1

    counts =
      Enum.reduce(run_timestamps, %{}, fn {_run, at}, acc ->
        idx = div(at, bucket_us)
        if idx >= first and idx <= last, do: Map.update(acc, idx, 1, &(&1 + 1)), else: acc
      end)

    %{
      bucket_ms: @live_bucket_ms,
      live?: true,
      segments: [
        %{
          start_us: first * bucket_us,
          counts: for(idx <- first..last, do: Map.get(counts, idx, 0)),
          gap_before_ms: nil
        }
      ],
      end_us: (last + 1) * bucket_us
    }
  end

  defp full_activity(_runs, []), do: nil

  defp full_activity(runs, run_timestamps) do
    grouped = Enum.group_by(run_timestamps, &elem(&1, 0), &elem(&1, 1))
    spans = Enum.map(runs, &run_span(&1, Map.get(grouped, &1.index, [])))
    bucket_ms = bucket_ms(spans)

    {segments, _prev_end} =
      runs
      |> Enum.zip(spans)
      |> Enum.map_reduce(nil, fn {run, {start_us, end_us}}, prev_end ->
        segment = %{
          start_us: start_us,
          counts: bucket_counts(Map.get(grouped, run.index, []), start_us, end_us, bucket_ms),
          gap_before_ms: prev_end && max(div(start_us - prev_end, 1_000), 0)
        }

        {segment, end_us}
      end)

    last = List.last(segments)

    %{
      bucket_ms: bucket_ms,
      live?: false,
      segments: segments,
      end_us: last.start_us + length(last.counts) * bucket_ms * 1_000
    }
  end

  defp run_span(run, ats) do
    start_us = DateTime.to_unix(run.started_at, :microsecond)

    end_us =
      case run.stopped_at do
        %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
        nil -> Enum.max(ats, fn -> start_us end)
      end

    {start_us, max(end_us, start_us)}
  end

  defp bucket_ms(spans) do
    total_ms = spans |> Enum.map(fn {from, to} -> div(to - from, 1_000) end) |> Enum.sum()

    Enum.find(@bucket_ladder_ms, List.last(@bucket_ladder_ms), fn bucket_ms ->
      div(total_ms + bucket_ms - 1, bucket_ms) + length(spans) <= @max_buckets
    end)
  end

  defp bucket_counts(ats, start_us, end_us, bucket_ms) do
    bucket_us = bucket_ms * 1_000
    count = max(div(end_us - start_us + bucket_us - 1, bucket_us), 1)

    counts =
      Enum.reduce(ats, %{}, fn at, acc ->
        idx = (at - start_us) |> div(bucket_us) |> max(0) |> min(count - 1)
        Map.update(acc, idx, 1, &(&1 + 1))
      end)

    for idx <- 0..(count - 1), do: Map.get(counts, idx, 0)
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
end
