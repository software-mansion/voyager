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
          <div id="node-info-content" class="mb-8 grid grid-cols-1 gap-6 lg:grid-cols-2">
            <NodeInfoComponents.memory_card memory={@snapshot.memory} />
            <NodeInfoComponents.limits_card limits={@snapshot.limits} />
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
