defmodule VoyagerWeb.TracingSessionLive.Stats do
  @moduledoc false

  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters

  @doc "`rates` holds the newest per-tick trace deltas, oldest first."
  @spec cells(Session.t(), [non_neg_integer()], DateTime.t(), non_neg_integer()) :: [map()]
  def cells(%Session{} = session, rates, now, storage_limit_mb) do
    [
      events(session),
      if(session.status == :stopped, do: stop_reason(session), else: rate(session, rates)),
      dropped(session),
      time(session, now),
      storage(session, storage_limit_mb)
    ]
  end

  defp events(%Session{traces: traces, run_traces_before: before, config: config}) do
    count = traces - before
    cell = %{key: :events, label: "Events", value: Formatters.format_integer(count)}

    case config.max_events do
      nil ->
        cell

      max ->
        Map.merge(cell, %{
          unit: "/ #{Formatters.format_integer(max)}",
          bar: [{"bg-primary", percent(count, max)}]
        })
    end
  end

  defp rate(%Session{config: config}, rates) do
    max_rate = config.max_rate
    scale = Enum.max([max_rate || 0 | rates])

    %{
      key: :rate,
      label: "Rate",
      value: Formatters.format_integer(List.last(rates, 0)),
      unit: if(max_rate, do: "/s of #{Formatters.format_integer(max_rate)}", else: "/s"),
      spark: Enum.map(rates, &percent(&1, scale))
    }
  end

  defp stop_reason(session) do
    %{
      key: :stop_reason,
      label: "Stop reason",
      value: TracingComponents.stop_reason_label(session.stop_reason),
      tip: TracingComponents.stop_reason_label(session.stop_reason),
      tone: if(TracingComponents.tone(session) == :failed, do: "text-warning")
    }
  end

  defp dropped(%Session{dropped: dropped}) do
    %{
      key: :dropped,
      label: "Dropped",
      value: Formatters.format_integer(dropped),
      tone: if(dropped > 0, do: "text-warning")
    }
  end

  defp time(%Session{status: :running, config: %{max_time_ms: max_ms}} = session, now)
       when is_integer(max_ms) do
    deadline = DateTime.add(session.run_started_at, max_ms, :millisecond)
    remaining_ms = max(DateTime.diff(deadline, now, :millisecond), 0)

    %{
      key: :auto_stop,
      label: "Auto-stop in",
      value: TracingComponents.format_elapsed(div(remaining_ms, 1_000)),
      bar: [{"bg-success", percent(remaining_ms, max_ms)}]
    }
  end

  defp time(%Session{config: config} = session, now) do
    ended_at = if session.status == :running, do: now, else: session.stopped_at
    elapsed = TracingComponents.format_elapsed(DateTime.diff(ended_at, session.run_started_at))
    cell = %{key: :run_time, label: "Run time", value: elapsed}

    case config.max_time_ms do
      nil -> cell
      max_ms -> Map.put(cell, :unit, "of #{TracingComponents.format_elapsed(div(max_ms, 1_000))}")
    end
  end

  # `storage_limit` is what the other saved sessions left of the shared limit.
  defp storage(%Session{save: true, bytes: bytes, storage_limit: left}, limit_mb) do
    limit = limit_mb * 1_000_000
    others = max(limit - left, 0)

    %{
      key: :storage,
      label: "Storage",
      value: format_size(bytes),
      unit: "of #{format_size(limit)}",
      bar: [
        {"bg-base-content/30", percent(others, limit)},
        {"bg-primary", if(bytes > 0, do: max(percent(bytes, limit), 1), else: 0)}
      ],
      tip: [
        {"This session", format_size(bytes)},
        {"Other saved sessions", format_size(others)},
        {"Free", format_size(max(left - bytes, 0))}
      ]
    }
  end

  defp storage(_session, _limit_mb) do
    %{
      key: :storage,
      label: "Storage",
      value: "Not saved",
      unit: "newest 500",
      tip: "Unsaved sessions keep only their newest 500 events, in memory"
    }
  end

  defp format_size(bytes) when bytes < 1_000_000,
    do: "#{Formatters.format_integer(div(bytes + 999, 1_000))} KB"

  defp format_size(bytes) when bytes < 100_000_000,
    do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp format_size(bytes), do: "#{Formatters.format_integer(div(bytes, 1_000_000))} MB"

  defp percent(part, whole) when whole > 0, do: min(max(div(part * 100, whole), 0), 100)
  defp percent(_part, _whole), do: 0
end
