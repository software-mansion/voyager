defmodule Voyager.Services.Tracer.Overview do
  @moduledoc """
  Pairs a session's control entries into runs.
  """

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Session

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
      outcome = run_outcome(stop, is_nil(next_seq), session, dropped_before(ordered, start.seq))

      build_run(index, start, next_seq, outcome, config, prev_config, now)
    end)
  end

  defp find_stop(ordered, start_seq, next_seq) do
    Enum.find(
      ordered,
      &(&1.kind == :stopped and &1.seq > start_seq and (is_nil(next_seq) or &1.seq < next_seq))
    )
  end

  defp config_at(ordered, start_seq) do
    ordered
    |> Enum.take_while(&(&1.seq < start_seq))
    |> Enum.reverse()
    |> Enum.find_value(&(&1.kind == :configured && &1.config))
  end

  defp build_run(index, start, next_seq, outcome, config, prev_config, now) do
    started_at = DateTime.from_unix!(start.at, :microsecond)
    {stopped_at, reason, traces, dropped} = outcome

    duration_ms =
      case stopped_at do
        %DateTime{} = at -> DateTime.diff(at, started_at, :millisecond)
        nil when reason == :running -> DateTime.diff(now, started_at, :millisecond)
        nil -> 0
      end
      |> max(0)

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

  # `session.dropped` counts every run's drops, a `:stopped` entry only its own run's.
  defp dropped_before(ordered, start_seq) do
    for %{kind: :stopped, seq: seq, dropped: dropped} <- ordered, seq < start_seq, reduce: 0 do
      sum -> sum + dropped
    end
  end

  defp run_outcome(%{} = stop, _last?, _session, _dropped_before) do
    {DateTime.from_unix!(stop.at, :microsecond), stop.reason, stop.traces, stop.dropped}
  end

  defp run_outcome(nil, true, %Session{status: :running} = session, dropped_before) do
    {nil, :running, max(session.traces - session.run_traces_before, 0),
     max(session.dropped - dropped_before, 0)}
  end

  # A nil stop stays nil: the session's `stopped_at` is the boot that interrupted it.
  defp run_outcome(nil, true, %Session{} = session, dropped_before) do
    {nil, session.stop_reason || :interrupted, max(session.traces - session.run_traces_before, 0),
     max(session.dropped - dropped_before, 0)}
  end

  defp run_outcome(nil, false, _session, _dropped_before), do: {nil, :interrupted, 0, 0}
end
