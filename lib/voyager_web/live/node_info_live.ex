defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.NodeInfo
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.NodeInfoComponents
  alias VoyagerWeb.NodeInfoHelp

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
        fetch_snapshot(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-screen-2xl p-6 sm:p-8">
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
          <label class="font-mono text-base-content/50 text-xs uppercase tracking-wider">
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
            phx-throttle="1000"
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
          <.loading_state id="node-info-loading" message="Fetching node info…" />
        </:loading>
        <:failed :let={reason}>
          <.error_state id="node-info-error" message={format_error(reason)} />
        </:failed>
        <div id="node-info-content">
          <%!-- Stat tiles --%>
          <div class="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <NodeInfoComponents.stat_tile
              label="Uptime"
              value={Formatters.format_uptime(snapshot.runtime.uptime_ms)}
              help={NodeInfoHelp.get(:uptime)}
            >
              <:sub>since {uptime_since(snapshot.collected_at, snapshot.runtime.uptime_ms)}</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="IO input"
              value={Formatters.format_bytes_compact(snapshot.runtime.io_input_bytes)}
              help={NodeInfoHelp.get(:io_input)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="IO output"
              value={Formatters.format_bytes_compact(snapshot.runtime.io_output_bytes)}
              help={NodeInfoHelp.get(:io_output)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
            <NodeInfoComponents.stat_tile
              label="Reductions"
              value={Formatters.format_count_compact(snapshot.runtime.total_reductions)}
              help={NodeInfoHelp.get(:reductions)}
            >
              <:sub>total since start</:sub>
            </NodeInfoComponents.stat_tile>
          </div>

          <%!-- Charts --%>
          <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2">
            <NodeInfoComponents.memory_card
              memory={snapshot.memory}
              help={NodeInfoHelp.get(:memory_breakdown)}
            />
            <NodeInfoComponents.limits_card limits={snapshot.limits} />
          </div>

          <%!-- Runtime + concurrency --%>
          <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2 lg:items-stretch">
            <NodeInfoComponents.info_card title="Runtime" rows={runtime_rows(snapshot)} />

            <div class="flex h-full min-h-0 flex-col gap-6">
              <NodeInfoComponents.metric_card
                title="Schedulers"
                subtitle="online / total"
                help={NodeInfoHelp.get(:schedulers)}
                metrics={[
                  {"Normal", "#{snapshot.schedulers.online} / #{snapshot.schedulers.total}"},
                  {"Dirty CPU",
                   "#{snapshot.schedulers.dirty_cpu_online} / #{snapshot.schedulers.dirty_cpu}"},
                  {"Dirty IO", snapshot.schedulers.dirty_io}
                ]}
              />
              <NodeInfoComponents.metric_card
                title="Run queues"
                subtitle="queued processes"
                help={NodeInfoHelp.get(:run_queues)}
                metrics={[
                  {"Normal + CPU", snapshot.run_queues.normal_and_dirty_cpu},
                  {"Dirty IO", snapshot.run_queues.dirty_io},
                  {"Total", snapshot.run_queues.total}
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
    socket |> fetch_snapshot() |> noreply()
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> schedule_refresh()
    |> noreply()
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket |> fetch_snapshot() |> noreply()
  end

  @impl true
  def handle_async(:snapshot, {:ok, {:ok, snapshot}}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.ok(socket.assigns.snapshot, snapshot))
    |> assign(:last_updated, DateTime.utc_now())
    |> schedule_refresh()
    |> noreply()
  end

  def handle_async(:snapshot, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.failed(socket.assigns.snapshot, reason))
    |> schedule_refresh()
    |> noreply()
  end

  def handle_async(:snapshot, {:exit, {:shutdown, :cancel}}, socket) do
    noreply(socket)
  end

  def handle_async(:snapshot, {:exit, reason}, socket) do
    socket
    |> assign(:snapshot, AsyncResult.failed(socket.assigns.snapshot, {:rpc, reason}))
    |> schedule_refresh()
    |> noreply()
  end

  defp fetch_snapshot(socket) do
    node = socket.assigns.session.node

    socket
    |> cancel_async(:snapshot, {:shutdown, :cancel})
    |> assign(:snapshot, AsyncResult.loading(socket.assigns.snapshot))
    |> start_async(:snapshot, fn ->
      NodeInfo.fetch(node)
    end)
  end

  defp schedule_refresh(socket) do
    if ref = socket.assigns.timer_ref, do: Process.cancel_timer(ref)

    ref =
      case socket.assigns.refresh_interval do
        nil ->
          nil

        ms when socket.assigns.snapshot.loading != true ->
          Process.send_after(self(), :refresh, ms)

        _ms ->
          nil
      end

    assign(socket, :timer_ref, ref)
  end

  @language_help %{"Elixir" => :elixir, "Gleam (stdlib)" => :gleam_stdlib}

  defp runtime_rows(snapshot) do
    language_rows =
      Enum.map(snapshot.languages, fn lang ->
        {lang.name, lang.version, help: NodeInfoHelp.get(@language_help[lang.name])}
      end)

    base = [
      {"OTP", snapshot.system.otp_release, help: NodeInfoHelp.get(:otp)},
      {"ERTS", snapshot.system.erts_version, help: NodeInfoHelp.get(:erts)},
      {"stdlib", snapshot.system.stdlib_version || "Not available",
       help: NodeInfoHelp.get(:stdlib)}
    ]

    rest = [
      {"Word size",
       "#{snapshot.system.wordsize_internal} / #{snapshot.system.wordsize_external} bytes",
       help: NodeInfoHelp.get(:word_size)},
      {"SMP", Formatters.format_bool(snapshot.system.smp_support?), help: NodeInfoHelp.get(:smp)},
      {"Threads", Formatters.format_bool(snapshot.system.thread_support?),
       help: NodeInfoHelp.get(:threads)},
      {"Async threads", to_string(snapshot.system.async_threads),
       help: NodeInfoHelp.get(:async_threads)},
      {"System arch", snapshot.system.system_architecture,
       help: NodeInfoHelp.get(:system_arch), full: true}
    ]

    language_rows ++ base ++ rest
  end

  defp uptime_since(%DateTime{} = collected_at, uptime_ms) when is_integer(uptime_ms) do
    started_at = DateTime.add(collected_at, -uptime_ms, :millisecond)
    Calendar.strftime(started_at, "%d %b %Y %H:%M UTC")
  end

  defp interval_options, do: @interval_options

  defp interval_value(nil), do: "off"
  defp interval_value(ms), do: Integer.to_string(ms)

  defp parse_interval("off"), do: nil

  defp parse_interval(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(:timeout), do: "Timed out while fetching node info."
  defp format_error({:rpc, _reason}), do: "RPC call failed while fetching node info."
  defp format_error({:internal, msg}), do: "Unexpected data from node: #{msg}"
  defp format_error(_), do: "Failed to fetch node info."
end
