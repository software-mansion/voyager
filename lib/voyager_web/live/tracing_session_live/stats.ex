defmodule VoyagerWeb.TracingSessionLive.Stats do
  @moduledoc """
  Owns the session bar's stats: the per-tick rate samples, the clock the run
  time is measured against, and the assigns they are rendered from (`now`,
  `rates`, `window_traces`, `last_trace_at`, `previous_trace_at`, `tick_scheduled?`,
  `storage_limit_mb`).

  Reads `mode` and `trace_session` from the socket.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import VoyagerWeb.Helpers, only: [cont: 1, halt: 1]

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters

  @tick_ms 1_000
  # An even rate spans a tick, give or take one 100 ms agent batch; a shorter span is a burst.
  @min_span_us (@tick_ms - 100) * 1_000
  @rate_history 10
  @kept_traces Tracer.kept_traces()

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:now, nil)
    |> assign(:rates, [])
    |> assign(:window_traces, 0)
    |> assign(:last_trace_at, nil)
    |> assign(:previous_trace_at, nil)
    |> assign(:tick_scheduled?, false)
    |> assign(:storage_limit_mb, Tracer.storage_limit_mb())
    |> attach_hook(:stats_tick, :handle_info, &handle_tick/2)
  end

  @doc "Restarts the rate samples when `session` is a new run of `shown`, and keeps ticking while it runs."
  @spec track(Socket.t(), Session.t() | nil, Session.t()) :: Socket.t()
  def track(socket, shown, session) do
    socket
    |> reset_rates(shown, session)
    |> assign(:now, DateTime.utc_now())
    |> tick()
  end

  @doc "Counts the traces among a broadcast's `entries` towards the next rate sample."
  @spec absorb(Socket.t(), [Entry.t()]) :: Socket.t()
  def absorb(socket, entries) do
    case for(%{kind: :trace, at: at} <- entries, do: at) do
      [] ->
        socket

      ats ->
        socket
        |> update(:window_traces, &(&1 + length(ats)))
        |> assign(:last_trace_at, Enum.max(ats))
    end
  end

  @doc "`rates` holds the newest per-tick trace rates, oldest first."
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
    cell = %{key: :events, label: "Events this run", value: Formatters.format_integer(count)}

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
      prose: true,
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
    elapsed_ms = DateTime.diff(ended_at, session.run_started_at, :millisecond)
    elapsed = TracingComponents.format_elapsed(div(elapsed_ms, 1_000))
    cell = %{key: :run_time, label: "Run time", value: elapsed}

    case config.max_time_ms do
      nil ->
        cell

      max_ms ->
        Map.merge(cell, %{
          unit: "of #{TracingComponents.format_elapsed(div(max_ms, 1_000))}",
          bar: [{"bg-base-content/40", percent(elapsed_ms, max_ms)}]
        })
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
      unit: "newest #{@kept_traces}",
      prose: true,
      tip: "Unsaved sessions keep only their newest #{@kept_traces} events, in memory"
    }
  end

  defp format_size(bytes) when bytes < 1_000_000,
    do: "#{Formatters.format_integer(div(bytes + 999, 1_000))} KB"

  defp format_size(bytes) when bytes < 100_000_000,
    do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp format_size(bytes), do: "#{Formatters.format_integer(div(bytes, 1_000_000))} MB"

  defp percent(part, whole) when whole > 0, do: min(max(div(part * 100, whole), 0), 100)
  defp percent(_part, _whole), do: 0

  defp handle_tick(:tick, %{assigns: %{trace_session: %AsyncResult{result: nil}}} = socket) do
    socket
    |> assign(:tick_scheduled?, false)
    |> halt()
  end

  defp handle_tick(:tick, socket) do
    %{window_traces: count, last_trace_at: last_at, previous_trace_at: previous_at} =
      socket.assigns

    socket
    |> assign(:tick_scheduled?, false)
    |> assign(:now, DateTime.utc_now())
    |> update(:rates, &Enum.take(&1 ++ [rate(count, last_at, previous_at)], -@rate_history))
    |> assign(:window_traces, 0)
    |> assign(:previous_trace_at, if(count > 0, do: last_at))
    |> tick()
    |> halt()
  end

  defp handle_tick(_message, socket), do: cont(socket)

  # Timed by the traces' own timestamps, so batching and tick drift do not jitter an even rate.
  defp rate(0, _last_at, _previous_at), do: 0

  defp rate(count, last_at, previous_at) when is_integer(previous_at) and last_at > previous_at,
    do: max(round(count * 1_000_000 / max(last_at - previous_at, @min_span_us)), 1)

  defp rate(count, _last_at, _previous_at), do: count

  defp reset_rates(socket, %Session{run_started_at: run}, %Session{run_started_at: run}),
    do: socket

  defp reset_rates(socket, _shown, _session) do
    socket
    |> assign(:rates, [])
    |> assign(:window_traces, 0)
    |> assign(:previous_trace_at, nil)
  end

  defp tick(
         %{
           assigns: %{
             tick_scheduled?: false,
             mode: :active,
             trace_session: %AsyncResult{result: %Session{status: :running}}
           }
         } = socket
       ) do
    Process.send_after(self(), :tick, @tick_ms)
    assign(socket, :tick_scheduled?, true)
  end

  defp tick(socket), do: socket
end
