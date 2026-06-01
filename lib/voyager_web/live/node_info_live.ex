defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.NodeInfo

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
    <div class="mx-auto max-w-[1536px] p-6 sm:p-8">
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
              class="select select-bordered select-sm font-mono text-xs"
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
          {render_snapshot(assign(assigns, :snapshot, @snapshot))}
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

  defp render_snapshot(assigns) do
    ~H"""
    <div id="node-info-content">
      <%!-- Hero stats --%>
      <div class="stats stats-vertical bg-base-200 border-base-300 mb-8 w-full border shadow-sm sm:stats-horizontal">
        <.hero_stat
          label="Uptime"
          value={format_uptime(@snapshot.runtime.uptime_ms)}
        />
        <.hero_stat
          label="Memory total"
          value={format_bytes(@snapshot.memory.total)}
          value_class="text-primary"
        />
        <.hero_stat
          label="Processes"
          value={format_int(@snapshot.limits.processes.used)}
          sub={"limit #{format_int(@snapshot.limits.processes.limit)}"}
        />
        <.hero_stat
          label="Schedulers"
          value={"#{@snapshot.schedulers.online} / #{@snapshot.schedulers.total}"}
          sub="online / total"
        />
      </div>

      <%!-- Memory + Limits --%>
      <div class="mb-8 grid grid-cols-1 gap-6 lg:grid-cols-3">
        <div class="card bg-base-200 border-base-300 border shadow-sm lg:col-span-2">
          <div class="card-body gap-4 p-5">
            <div class="flex items-baseline justify-between">
              <h2 class="font-mono text-base-content text-sm font-semibold uppercase tracking-wider">
                Memory breakdown
              </h2>
              <span class="font-mono text-base-content/50 text-xs">
                {format_bytes(@snapshot.memory.total)} total
              </span>
            </div>

            <div class="bg-base-300 flex h-3 w-full overflow-hidden rounded-full">
              <div
                :for={{label, bytes, color} <- memory_segments(@snapshot.memory)}
                class={color}
                style={"width: #{pct(bytes, @snapshot.memory.total)}%"}
                title={"#{label}: #{format_bytes(bytes)}"}
              >
              </div>
            </div>

            <div class="grid grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-3 lg:grid-cols-6">
              <div
                :for={{label, bytes, color} <- memory_segments(@snapshot.memory)}
                class="flex items-center gap-2"
              >
                <span class={["size-2.5 flex-none rounded-full", color]}></span>
                <span class="font-mono text-base-content/70 text-xs">{label}</span>
                <span class="font-mono text-base-content ml-auto text-xs tabular-nums">
                  {format_bytes(bytes)}
                </span>
              </div>
            </div>

            <div class="font-mono text-base-content/40 border-base-300 text-[10px] mt-1 border-t pt-3 tracking-wide">
              processes {format_bytes(@snapshot.memory.processes_used)} used of {format_bytes(
                @snapshot.memory.processes_allocated
              )} · atoms {format_bytes(@snapshot.memory.atom_used)} used of {format_bytes(
                @snapshot.memory.atom_allocated
              )}
            </div>
          </div>
        </div>

        <div class="card bg-base-200 border-base-300 border shadow-sm">
          <div class="card-body gap-4 p-5">
            <div class="flex items-baseline justify-between">
              <h2 class="font-mono text-base-content text-sm font-semibold uppercase tracking-wider">
                System limits
              </h2>
              <span class="font-mono text-base-content/50 text-xs">used / limit</span>
            </div>

            <div class="space-y-3">
              <div :for={{label, usage} <- limit_rows(@snapshot.limits)} class="space-y-1">
                <div class="font-mono flex items-baseline justify-between text-xs">
                  <span class="text-base-content/70">{label}</span>
                  <span class="text-base-content tabular-nums">
                    {format_int(usage.used)} / {format_int(usage.limit)}
                  </span>
                </div>
                <progress
                  class={["progress w-full", progress_color(usage)]}
                  value={usage.used}
                  max={usage.limit}
                >
                </progress>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Runtime counters --%>
      <.info_section title="Runtime counters">
        <.info_card label="Uptime" value={format_uptime(@snapshot.runtime.uptime_ms)} />
        <.info_card label="Total reductions" value={format_int(@snapshot.runtime.total_reductions)} />
        <.info_card label="IO input" value={format_bytes(@snapshot.runtime.io_input_bytes)} />
        <.info_card label="IO output" value={format_bytes(@snapshot.runtime.io_output_bytes)} />
      </.info_section>

      <%!-- System --%>
      <.info_section title="System">
        <.info_card label="OTP release" value={@snapshot.system.otp_release} />
        <.info_card label="ERTS version" value={@snapshot.system.erts_version} />
        <.info_card label="Architecture" value={@snapshot.system.system_architecture} />
        <.info_card
          label="Word size"
          value={"#{@snapshot.system.wordsize_internal} / #{@snapshot.system.wordsize_external} bytes"}
        />
        <.info_card label="SMP support" value={format_bool(@snapshot.system.smp_support?)} />
        <.info_card label="Thread support" value={format_bool(@snapshot.system.thread_support?)} />
        <.info_card label="Async threads" value={format_int(@snapshot.system.async_threads)} />
        <.info_card label="Version" value={@snapshot.system.system_version} />
      </.info_section>

      <%!-- Schedulers, processors, run queues --%>
      <.info_section title="Schedulers & processors">
        <.info_card
          label="Schedulers"
          value={"#{@snapshot.schedulers.online} / #{@snapshot.schedulers.total}"}
        />
        <.info_card label="Schedulers available" value={format_value(@snapshot.schedulers.available)} />
        <.info_card
          label="Processors"
          value={"#{format_value(@snapshot.processors.online)} / #{format_value(@snapshot.processors.total)}"}
        />
        <.info_card label="Processors available" value={format_value(@snapshot.processors.available)} />
        <.info_card label="Run queue total" value={format_int(@snapshot.run_queues.total)} />
        <.info_card
          label="Run queue normal + dirty CPU"
          value={format_int(@snapshot.run_queues.normal_and_dirty_cpu)}
        />
        <.info_card label="Run queue dirty IO" value={format_int(@snapshot.run_queues.dirty_io)} />
      </.info_section>

      <%!-- Languages --%>
      <section class="mb-8">
        <h2 class="font-mono text-base-content/50 text-[11px] tracking-[0.15em] mb-3 ml-1 font-semibold uppercase">
          Languages
        </h2>
        <%= if @snapshot.languages == [] do %>
          <div class="card bg-base-200 border-base-300 border shadow-sm">
            <div class="card-body p-4">
              <span class="font-mono text-base-content/50 text-sm">
                No BEAM languages detected on this node.
              </span>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <.info_card :for={lang <- @snapshot.languages} label={lang.name} value={lang.version} />
          </div>
        <% end %>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :value_class, :any, default: nil

  defp hero_stat(assigns) do
    ~H"""
    <div class="stat">
      <div class="stat-title font-mono text-[10.5px] uppercase tracking-wider">{@label}</div>
      <div class={["stat-value font-mono text-2xl tabular-nums", @value_class]}>{@value}</div>
      <div :if={@sub} class="stat-desc font-mono text-[11px]">{@sub}</div>
    </div>
    """
  end

  defp interval_options, do: @interval_options

  defp interval_value(nil), do: "off"
  defp interval_value(ms), do: Integer.to_string(ms)

  defp memory_segments(memory) do
    [
      {"Processes", memory.processes_allocated, "bg-[var(--chart-1)]"},
      {"Atoms", memory.atom_allocated, "bg-[var(--chart-2)]"},
      {"Binary", memory.binary, "bg-[var(--chart-3)]"},
      {"Code", memory.code, "bg-[var(--chart-4)]"},
      {"ETS", memory.ets, "bg-[var(--chart-5)]"},
      {"Other", memory.other, "bg-[var(--chart-6)]"}
    ]
  end

  defp limit_rows(limits) do
    [
      {"Processes", limits.processes},
      {"Ports", limits.ports},
      {"Atoms", limits.atoms},
      {"ETS", limits.ets}
    ]
  end

  defp progress_color(%{used: used, limit: limit}) when limit > 0 do
    cond do
      used / limit * 100 >= 90 -> "progress-error"
      used / limit * 100 >= 70 -> "progress-warning"
      true -> "progress-primary"
    end
  end

  defp progress_color(_), do: "progress-primary"

  defp pct(_part, total) when total <= 0, do: 0
  defp pct(part, total), do: Float.round(part / total * 100, 2)

  defp format_bytes(n) when is_integer(n) do
    cond do
      n >= 1_073_741_824 -> "#{Float.round(n / 1_073_741_824, 2)} GB"
      n >= 1_048_576 -> "#{Float.round(n / 1_048_576, 1)} MB"
      n >= 1_024 -> "#{Float.round(n / 1_024, 1)} KB"
      true -> "#{n} B"
    end
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_uptime(ms) when is_integer(ms) do
    total_seconds = div(ms, 1_000)
    days = div(total_seconds, 86_400)
    hours = total_seconds |> rem(86_400) |> div(3_600)
    minutes = total_seconds |> rem(3_600) |> div(60)
    seconds = rem(total_seconds, 60)

    clock =
      Enum.map_join(
        [hours, minutes, seconds],
        ":",
        &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
      )

    if days > 0, do: "#{days}d #{clock}", else: clock
  end

  defp format_bool(true), do: "enabled"
  defp format_bool(false), do: "disabled"

  defp format_value(:unknown), do: "—"
  defp format_value(n) when is_integer(n), do: format_int(n)
  defp format_value(other), do: to_string(other)

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(:timeout), do: "Timed out while fetching node info."
  defp format_error({:rpc, _reason}), do: "RPC call failed while fetching node info."
  defp format_error({:internal, msg}), do: "Unexpected data from node: #{msg}"
  defp format_error(_), do: "Failed to fetch node info."
end
