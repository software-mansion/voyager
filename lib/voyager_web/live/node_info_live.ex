defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.NodeInfo
  alias VoyagerWeb.NodeInfoComponents

  @default_interval 5_000

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
      |> assign(:snapshot, nil)
      |> assign(:error, nil)
      |> assign(:loading, false)
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
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> fetch_snapshot() |> schedule_refresh()}
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    {:noreply,
     socket
     |> assign(:refresh_interval, parse_interval(value))
     |> schedule_refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> fetch_snapshot() |> schedule_refresh()}
  end

  @impl true
  def handle_async(:snapshot, {:ok, {:ok, snapshot}}, socket) do
    {:noreply,
     socket
     |> assign(:snapshot, snapshot)
     |> assign(:error, nil)
     |> assign(:loading, false)
     |> assign(:last_updated, DateTime.utc_now())}
  end

  def handle_async(:snapshot, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:error, reason) |> assign(:loading, false)}
  end

  def handle_async(:snapshot, {:exit, reason}, socket) do
    {:noreply, socket |> assign(:error, {:rpc, reason}) |> assign(:loading, false)}
  end

  defp fetch_snapshot(socket) do
    node = socket.assigns.session.node

    socket
    |> assign(:loading, true)
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
              updated {format_time(@last_updated)} UTC
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
            <.icon name="icon-rotate-cw" class={["size-4", @loading && "animate-spin"]} />
          </button>
        </div>
      </header>

      <div :if={@error} class="alert alert-error mb-8" id="node-info-error" role="alert">
        <.icon name="icon-circle-alert" class="size-5" />
        <span>{format_error(@error)}</span>
      </div>

      <%= cond do %>
        <% @snapshot -> %>
          <div id="node-info-content">
            <%!-- Stat tiles --%>
            <div class="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
              <NodeInfoComponents.stat_tile
                label="Uptime"
                value={"#{uptime_value(@snapshot.runtime.uptime_ms)}#{uptime_unit(@snapshot.runtime.uptime_ms)}"}
              >
                <:sub>since {uptime_since(@snapshot.collected_at, @snapshot.runtime.uptime_ms)}</:sub>
              </NodeInfoComponents.stat_tile>
              <NodeInfoComponents.stat_tile
                label="IO input"
                value={"#{io_value(@snapshot.runtime.io_input_bytes)}#{io_unit(@snapshot.runtime.io_input_bytes)}"}
              >
                <:sub>total since start</:sub>
              </NodeInfoComponents.stat_tile>
              <NodeInfoComponents.stat_tile
                label="IO output"
                value={"#{io_value(@snapshot.runtime.io_output_bytes)}#{io_unit(@snapshot.runtime.io_output_bytes)}"}
              >
                <:sub>total since start</:sub>
              </NodeInfoComponents.stat_tile>
              <NodeInfoComponents.stat_tile
                label="Reductions"
                value={"#{reductions_value(@snapshot.runtime.total_reductions)}#{reductions_unit(@snapshot.runtime.total_reductions)}"}
              >
                <:sub>total since start</:sub>
              </NodeInfoComponents.stat_tile>
            </div>

            <%!-- Charts --%>
            <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2">
              <NodeInfoComponents.memory_card memory={@snapshot.memory} />
              <NodeInfoComponents.limits_card limits={@snapshot.limits} />
            </div>

            <%!-- Runtime + concurrency --%>
            <div class="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2 lg:items-stretch">
              <NodeInfoComponents.info_card title="Runtime" rows={runtime_rows(@snapshot)} />

              <div class="flex h-full min-h-0 flex-col gap-6">
                <NodeInfoComponents.metric_card
                  title="Schedulers"
                  subtitle="online / total"
                  metrics={[
                    {"Normal", "#{@snapshot.schedulers.online} / #{@snapshot.schedulers.total}"},
                    {"Dirty CPU",
                     "#{@snapshot.schedulers.dirty_cpu_online} / #{@snapshot.schedulers.dirty_cpu}"},
                    {"Dirty IO", metric(@snapshot.schedulers.dirty_io)}
                  ]}
                />
                <NodeInfoComponents.metric_card
                  title="Run queues"
                  subtitle="queued processes"
                  metrics={[
                    {"Total", metric(@snapshot.run_queues.total)},
                    {"Normal + CPU", metric(@snapshot.run_queues.normal_and_dirty_cpu)},
                    {"Dirty IO", metric(@snapshot.run_queues.dirty_io)}
                  ]}
                />
              </div>
            </div>
          </div>
        <% @error -> %>
          <%!-- error already shown above; nothing more to render --%>
        <% true -> %>
          <div class="flex items-center justify-center gap-3 py-24" id="node-info-loading">
            <span class="loading loading-spinner loading-md text-primary"></span>
            <span class="font-mono text-base-content/50 text-sm">Fetching node info…</span>
          </div>
      <% end %>
    </div>
    """
  end

  defp reductions_value(n) when n >= 1_000_000_000, do: Float.round(n / 1_000_000_000, 1)
  defp reductions_value(n) when n >= 10_000_000, do: Float.round(n / 1_000_000, 1)

  defp reductions_value(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp reductions_unit(n) when n >= 1_000_000_000, do: "B"
  defp reductions_unit(n) when n >= 10_000_000, do: "M"
  defp reductions_unit(_n), do: nil

  defp io_value(bytes) when bytes >= 1_099_511_627_776,
    do: Float.round(bytes / 1_099_511_627_776, 1)

  defp io_value(bytes) when bytes >= 1_073_741_824, do: Float.round(bytes / 1_073_741_824, 1)
  defp io_value(bytes) when bytes >= 1_048_576, do: round(bytes / 1_048_576)
  defp io_value(bytes) when bytes >= 1_024, do: round(bytes / 1_024)
  defp io_value(bytes), do: bytes

  defp io_unit(bytes) when bytes >= 1_099_511_627_776, do: "TB"
  defp io_unit(bytes) when bytes >= 1_073_741_824, do: "GB"
  defp io_unit(bytes) when bytes >= 1_048_576, do: "MB"
  defp io_unit(bytes) when bytes >= 1_024, do: "KB"
  defp io_unit(_bytes), do: "B"

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
      {"SMP support", format_bool(snapshot.system.smp_support?)},
      {"Threads", format_bool(snapshot.system.thread_support?)},
      {"Async threads", to_string(snapshot.system.async_threads)},
      {"System arch", snapshot.system.system_architecture, :full}
    ]

    base ++ stdlib ++ language_rows ++ rest
  end

  defp metric(n) when is_integer(n), do: Integer.to_string(n)

  defp format_bool(true), do: "enabled"
  defp format_bool(false), do: "disabled"

  defp uptime_parts(ms) when is_integer(ms) do
    total_seconds = div(ms, 1_000)
    years = div(total_seconds, 31_536_000)
    days = total_seconds |> rem(31_536_000) |> div(86_400)
    hours = total_seconds |> rem(86_400) |> div(3_600)
    minutes = total_seconds |> rem(3_600) |> div(60)
    seconds = rem(total_seconds, 60)
    {years, days, hours, minutes, seconds}
  end

  defp uptime_value(ms) do
    {years, days, hours, minutes, seconds} = uptime_parts(ms)

    cond do
      years > 0 -> years
      days > 0 -> days
      hours > 0 -> hours
      minutes > 0 -> minutes
      true -> seconds
    end
  end

  defp uptime_unit(ms) do
    {years, days, hours, minutes, _seconds} = uptime_parts(ms)

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

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(:timeout), do: "Timed out while fetching node info."
  defp format_error({:rpc, _reason}), do: "RPC call failed while fetching node info."
  defp format_error({:internal, msg}), do: "Unexpected data from node: #{msg}"
  defp format_error(_), do: "Failed to fetch node info."
end
