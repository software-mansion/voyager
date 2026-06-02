defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.NodeInfo
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.NodeInfoComponents

  @default_interval Application.compile_env(:voyager, :node_info_refresh_interval_ms, 5_000)

  @interval_options [
    {"Off", "off"},
    {"1s", "1000"},
    {"2s", "2000"},
    {"5s", "5000"},
    {"10s", "10000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :node_info)
      |> assign(:refresh_interval, @default_interval)
      |> assign(:snapshot, AsyncResult.loading())
      |> assign(:last_updated, nil)
      |> assign(:timer_ref, nil)

    socket =
      if connected?(socket) do
        socket |> fetch_snapshot() |> schedule_refresh()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[1536px] mx-auto p-6 sm:p-8">
      <header class="mb-8 flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="font-mono text-base-content text-2xl font-bold tracking-tight">
            {@session.node_name}
          </h1>
          <p class="font-mono text-base-content/50 mt-0.5 text-xs">
            <%= if @last_updated do %>
              updated {Formatters.format_time(@last_updated)} UTC
            <% else %>
              waiting for first snapshot…
            <% end %>
          </p>
        </div>

        <div class="flex items-center gap-2">
          <label class="font-mono text-base-content/50 text-[11px] uppercase tracking-wider">
            Auto-refresh
          </label>
          <form phx-change="set_interval" id="refresh-interval-form">
            <select
              name="interval"
              id="refresh-interval"
              class="select select-bordered select-sm font-mono pr-8 text-xs"
            >
              <option
                :for={{label, value} <- interval_options()}
                value={value}
                selected={value == interval_value(@refresh_interval)}
              >
                {label}
              </option>
            </select>
          </form>
          <button
            type="button"
            phx-click="refresh"
            id="refresh-now"
            title="Refresh now"
            class="btn btn-sm btn-ghost btn-square"
          >
            <.icon name="icon-rotate-cw" class={["size-4", @snapshot.loading && "animate-spin"]} />
          </button>
        </div>
      </header>

      <.async_result :let={snapshot} assign={@snapshot}>
        <:loading>
          <div class="flex items-center justify-center gap-3 py-24" id="node-info-loading">
            <span class="loading loading-spinner loading-md text-primary"></span>
            <span class="font-mono text-base-content/50 text-sm">Fetching node info…</span>
          </div>
        </:loading>
        <:failed :let={reason}>
          <div class="alert alert-error mb-8" id="node-info-error" role="alert">
            <.icon name="icon-circle-alert" class="size-5" />
            <span>{format_error(reason)}</span>
          </div>
        </:failed>
        <div id="node-info-content">
          <%!-- Stat tiles --%>
          <div class="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <NodeInfoComponents.stat_tile
              label="Uptime"
              value={"#{uptime_value(snapshot.runtime.uptime_ms)}#{uptime_unit(snapshot.runtime.uptime_ms)}"}
            >
              <:sub>since {uptime_since(snapshot.collected_at, snapshot.runtime.uptime_ms)}</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="IO input"
              value={byte_label(snapshot.runtime.io_input_bytes)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="IO output"
              value={byte_label(snapshot.runtime.io_output_bytes)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="Reductions"
              value={count_label(snapshot.runtime.total_reductions)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
          </div>

          <%!-- Charts --%>
          <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2">
            <NodeInfoComponents.memory_card memory={snapshot.memory} />
            <NodeInfoComponents.limits_card limits={snapshot.limits} />
          </div>

          <%!-- Runtime + concurrency --%>
          <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2 lg:items-stretch">
            <NodeInfoComponents.info_card title="Runtime" rows={runtime_rows(snapshot)} />

            <div class="flex h-full min-h-0 flex-col gap-6">
              <NodeInfoComponents.metric_card
                title="Schedulers"
                subtitle="online / total"
                metrics={[
                  {"Normal", "#{snapshot.schedulers.online} / #{snapshot.schedulers.total}"},
                  {"Dirty CPU",
                   "#{snapshot.schedulers.dirty_cpu_online} / #{snapshot.schedulers.dirty_cpu}"},
                  {"Dirty IO", metric(snapshot.schedulers.dirty_io)}
                ]}
              />
              <NodeInfoComponents.metric_card
                title="Run queues"
                subtitle="queued processes"
                metrics={[
                  {"Total", metric(snapshot.run_queues.total)},
                  {"Normal + CPU", metric(snapshot.run_queues.normal_and_dirty_cpu)},
                  {"Dirty IO", metric(snapshot.run_queues.dirty_io)}
                ]}
              />
            </div>
          </div>
        </div>
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket |> fetch_snapshot() |> schedule_refresh() |> noreply()
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> schedule_refresh()
    |> noreply()
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket |> fetch_snapshot() |> schedule_refresh() |> noreply()
  end

  @impl true
  def handle_async(:snapshot, {:ok, {:ok, snapshot}}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.ok(socket.assigns.snapshot, snapshot))
    |> assign(:last_updated, DateTime.utc_now())
    |> noreply()
  end

  def handle_async(:snapshot, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.failed(socket.assigns.snapshot, reason))
    |> noreply()
  end

  def handle_async(:snapshot, {:exit, reason}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.failed(socket.assigns.snapshot, {:rpc, reason}))
    |> noreply()
  end

  defp fetch_snapshot(socket) do
    node = socket.assigns.session.node

    socket
    |> assign(:snapshot, AsyncResult.loading(socket.assigns.snapshot))
    |> start_async(:snapshot, fn -> NodeInfo.fetch(node) end)
  end

  defp schedule_refresh(socket) do
    if ref = socket.assigns.timer_ref, do: Process.cancel_timer(ref)

    ref =
      case socket.assigns.refresh_interval do
        nil -> nil
        ms -> Process.send_after(self(), :refresh, ms)
      end

    assign(socket, :timer_ref, ref)
  end

  defp parse_interval("off"), do: nil
  defp parse_interval(value), do: String.to_integer(value)

  # Compact, unit-suffixed labels (no space) for the stat tiles.
  defp byte_label(bytes) do
    {value, unit} = Formatters.byte_parts(bytes)
    "#{value}#{unit}"
  end

  defp count_label(n) do
    {value, unit} = Formatters.count_parts(n)
    "#{value}#{unit}"
  end

  defp runtime_rows(snapshot) do
    language_rows = Enum.map(snapshot.languages, &{&1.name, &1.version})

    base = [
      {"OTP release", snapshot.system.otp_release},
      {"ERTS version", snapshot.system.erts_version}
    ]

    stdlib =
      if snapshot.system.stdlib_version,
        do: [{"stdlib", snapshot.system.stdlib_version}],
        else: []

    rest = [
      {"Word size",
       "#{snapshot.system.wordsize_internal} / #{snapshot.system.wordsize_external} bytes"},
      {"SMP support", Formatters.format_bool(snapshot.system.smp_support?)},
      {"Threads", Formatters.format_bool(snapshot.system.thread_support?)},
      {"Async threads", to_string(snapshot.system.async_threads)},
      {"System arch", snapshot.system.system_architecture, :full}
    ]

    base ++ stdlib ++ language_rows ++ rest
  end

  defp metric(n) when is_integer(n), do: Integer.to_string(n)

  defp uptime_value(ms) do
    {years, days, hours, minutes, seconds} = Formatters.duration_parts(ms)

    cond do
      years > 0 -> years
      days > 0 -> days
      hours > 0 -> hours
      minutes > 0 -> minutes
      true -> seconds
    end
  end

  defp uptime_unit(ms) do
    {years, days, hours, minutes, _seconds} = Formatters.duration_parts(ms)

    cond do
      years > 0 -> "yr #{days}d"
      days > 0 -> "d #{hours}h"
      hours > 0 -> "h #{minutes}m"
      minutes > 0 -> "m"
      true -> "s"
    end
  end

  defp uptime_since(%DateTime{} = collected_at, uptime_ms) when is_integer(uptime_ms) do
    started_at = DateTime.add(collected_at, -uptime_ms, :millisecond)
    Calendar.strftime(started_at, "%d %b %Y %H:%M UTC")
  end

  defp interval_options, do: @interval_options

  defp interval_value(nil), do: "off"
  defp interval_value(ms), do: Integer.to_string(ms)

  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(:timeout), do: "Timed out while fetching node info."
  defp format_error({:rpc, _reason}), do: "RPC call failed while fetching node info."
  defp format_error({:internal, msg}), do: "Unexpected data from node: #{msg}"
  defp format_error(_), do: "Failed to fetch node info."
end
