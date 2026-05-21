defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Inspector.Fetch
  alias Voyager.Inspector.Remote
  alias Voyager.Node
  alias VoyagerWeb.SupervisionTreeLive.Diff

  @refresh_interval 5_000
  @max_selected_apps 20
  @default_depth 3

  @impl true
  def mount(%{"node" => node_str}, _session, socket) do
    node_atom =
      try do
        String.to_existing_atom(node_str)
      rescue
        ArgumentError -> nil
      end

    if is_nil(node_atom) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      voyager_node = %Node{name: node_atom, status: :connected, connected_at: nil, cookie: nil}

      socket =
        socket
        |> assign(:node, voyager_node)
        |> assign(:active_nav, :supervision_tree)
        |> assign(:available_apps, [])
        |> assign(:selected_apps, MapSet.new())
        |> assign(:depth, @default_depth)
        |> assign(:expanded_pids, MapSet.new())
        |> assign(:last_tree_flat, nil)
        |> assign(:in_flight, nil)
        |> assign(:errors, [])
        |> assign(:status, :idle)
        |> assign(:last_refreshed_at, nil)
        |> assign(:refresh_timer, nil)
        |> assign(:apps_form, to_form(%{}, as: :tree_controls))

      socket =
        if connected?(socket) do
          socket =
            case Remote.list_applications(node_atom) do
              {:ok, apps} ->
                available =
                  apps
                  |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
                  |> Enum.sort()

                assign(socket, :available_apps, available)

              {:error, reason} ->
                socket
                |> assign(:status, :error)
                |> assign(:errors, [{:list_applications, node_atom, reason}])
            end

          timer = Process.send_after(self(), :refresh, @refresh_interval)
          assign(socket, :refresh_timer, timer)
        else
          socket
        end

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("select-apps", params, socket) do
    inner = Map.get(params, "tree_controls", params)

    app_strings = Map.get(inner, "apps", [])
    app_strings = if is_list(app_strings), do: app_strings, else: [app_strings]

    apps =
      app_strings
      |> Enum.flat_map(fn s ->
        try do
          [String.to_existing_atom(s)]
        rescue
          ArgumentError -> []
        end
      end)

    {apps, truncated?} =
      if length(apps) > @max_selected_apps do
        {Enum.take(apps, @max_selected_apps), true}
      else
        {apps, false}
      end

    socket =
      if truncated? do
        put_flash(
          socket,
          :info,
          "Only #{@max_selected_apps} applications can be selected at once."
        )
      else
        socket
      end

    depth_str = Map.get(inner, "depth", to_string(@default_depth))

    depth =
      case Integer.parse(depth_str) do
        {d, ""} -> d |> max(1) |> min(10)
        _ -> socket.assigns.depth
      end

    new_apps = MapSet.new(apps)
    scope_changed? = new_apps != socket.assigns.selected_apps or depth != socket.assigns.depth

    socket =
      socket
      |> assign(:selected_apps, new_apps)
      |> assign(:depth, depth)

    socket = if scope_changed?, do: reset_tree(socket), else: socket

    {:noreply, request_fetch(socket)}
  end

  def handle_event("set-depth", %{"depth" => depth_str}, socket) do
    depth =
      case Integer.parse(depth_str) do
        {d, ""} -> d |> max(1) |> min(10)
        _ -> socket.assigns.depth
      end

    scope_changed? = depth != socket.assigns.depth

    socket = assign(socket, :depth, depth)
    socket = if scope_changed?, do: reset_tree(socket), else: socket

    {:noreply, request_fetch(socket)}
  end

  def handle_event("toggle-expand", %{"pid" => pid_str}, socket) do
    pid =
      try do
        pid_str |> String.to_charlist() |> :erlang.list_to_pid()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    if is_nil(pid) do
      {:noreply, socket}
    else
      expanded = socket.assigns.expanded_pids

      {expanded, newly_expanded?} =
        if MapSet.member?(expanded, pid) do
          {MapSet.delete(expanded, pid), false}
        else
          {MapSet.put(expanded, pid), true}
        end

      socket =
        socket
        |> assign(:expanded_pids, expanded)

      socket =
        if newly_expanded? do
          request_fetch(socket)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_event("refresh-now", _params, socket) do
    {:noreply, request_fetch(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    timer = Process.send_after(self(), :refresh, @refresh_interval)
    socket = assign(socket, :refresh_timer, timer)

    socket =
      if MapSet.size(socket.assigns.selected_apps) > 0 and is_nil(socket.assigns.in_flight) do
        request_fetch(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({ref, {status, tree, errors}}, socket) do
    in_flight = socket.assigns.in_flight

    if not is_nil(in_flight) and in_flight.ref == ref do
      Process.demonitor(ref, [:flush])

      new_flat = Diff.flatten(tree)
      prev_flat = socket.assigns.last_tree_flat

      payload =
        case prev_flat do
          nil ->
            %{kind: "full", nodes: new_flat, status: status, errors: errors}

          prev ->
            d = Diff.diff(prev, new_flat)
            Map.merge(d, %{kind: "delta", status: status, errors: errors})
        end

      socket =
        socket
        |> assign(:errors, errors)
        |> assign(:status, status)
        |> assign(:last_refreshed_at, DateTime.utc_now())
        |> assign(:in_flight, nil)
        |> assign(:last_tree_flat, new_flat)
        |> push_event("tree-data", payload)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    in_flight = socket.assigns.in_flight

    if not is_nil(in_flight) and in_flight.ref == ref do
      socket =
        socket
        |> assign(:in_flight, nil)
        |> assign(:status, :error)
        |> assign(:errors, socket.assigns.errors ++ [{:fetch, reason}])
        |> reset_tree()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:in_flight] do
      Fetch.cancel(socket.assigns.in_flight)
    end

    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col gap-4 p-4">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body flex flex-row items-center gap-4 py-3">
          <div class="flex-1">
            <h1 class="card-title text-base-content">Supervision Tree</h1>
            <p class="text-base-content/60 text-sm">{@node.name}</p>
          </div>
          <div class="flex items-center gap-3">
            <span class={["badge", status_badge_class(@status)]}>
              {status_label(@status)}
            </span>
            <%= if @last_refreshed_at do %>
              <span class="text-base-content/50 text-xs">
                refreshed {relative_time(@last_refreshed_at)}
              </span>
            <% end %>
            <button
              id="supervision-tree-refresh"
              class="btn btn-sm btn-ghost"
              phx-click="refresh-now"
              title="Refresh now"
            >
              <.icon
                name="icon-rotate-cw"
                class={["size-4", @status == :loading && "animate-spin"]}
              />
            </button>
          </div>
        </div>
      </div>

      <%!-- Controls --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body py-3">
          <.form
            for={@apps_form}
            id="supervision-tree-controls"
            phx-change="select-apps"
            class="flex flex-col gap-3"
          >
            <div class="flex items-center justify-between">
              <h2 class="text-base-content text-sm font-semibold">Applications</h2>
              <div class="flex items-center gap-2">
                <label class="label text-base-content/60 text-xs" for="depth-input">Depth</label>
                <input
                  id="depth-input"
                  type="number"
                  name="depth"
                  min="1"
                  max="10"
                  value={@depth}
                  class="input input-sm input-bordered w-16 text-center"
                />
              </div>
            </div>
            <div class="flex flex-wrap gap-2">
              <%= if @available_apps == [] do %>
                <span class="text-base-content/50 text-sm italic">No applications available</span>
              <% else %>
                <%= for {app, vsn} <- @available_apps do %>
                  <label class={[
                    "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition-colors",
                    MapSet.member?(@selected_apps, app) && "border-primary bg-primary/10 text-primary",
                    not MapSet.member?(@selected_apps, app) &&
                      "border-base-300 bg-base-200 text-base-content hover:border-primary/50"
                  ]}>
                    <input
                      type="checkbox"
                      name="apps[]"
                      value={to_string(app)}
                      checked={MapSet.member?(@selected_apps, app)}
                      class="checkbox checkbox-xs checkbox-primary"
                    />
                    <span class="font-mono">{app}</span>
                    <span class="badge badge-ghost badge-xs">{vsn}</span>
                  </label>
                <% end %>
              <% end %>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Errors --%>
      <%= if @errors != [] do %>
        <div id="supervision-tree-errors" class="alert alert-error">
          <.icon name="icon-circle-alert" class="size-4 shrink-0" />
          <div>
            <p class="font-semibold">Errors encountered</p>
            <ul class="mt-1 list-inside list-disc text-sm">
              <%= for err <- @errors do %>
                <li>{inspect(err)}</li>
              <% end %>
            </ul>
          </div>
        </div>
      <% end %>

      <%!-- Body --%>
      <div class="flex-1 overflow-auto">
        <%= cond do %>
          <% MapSet.size(@selected_apps) == 0 -> %>
            <div class="border-base-300 flex h-64 flex-col items-center justify-center gap-3 rounded-lg border border-dashed text-center">
              <.icon name="icon-network" class="size-10 text-base-content/30" />
              <div>
                <p class="text-base-content/60 font-medium">No applications selected</p>
                <p class="text-base-content/40 text-sm">
                  Select one or more applications to inspect.
                </p>
              </div>
            </div>
          <% @status == :idle -> %>
            <div class="border-base-300 flex h-64 flex-col items-center justify-center gap-3 rounded-lg border border-dashed text-center">
              <.icon name="icon-network" class="size-10 text-base-content/30" />
              <div>
                <p class="text-base-content/60 font-medium">Waiting…</p>
              </div>
            </div>
          <% true -> %>
            <div
              id="supervision-tree-body"
              phx-hook="SupervisionTree"
              phx-update="ignore"
              class="bg-base-100 min-h-64 rounded-lg p-4 shadow-sm"
            >
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp reset_tree(socket), do: assign(socket, :last_tree_flat, nil)

  defp request_fetch(socket) do
    if socket.assigns.in_flight do
      Fetch.cancel(socket.assigns.in_flight)
    end

    selected = MapSet.to_list(socket.assigns.selected_apps)

    if selected == [] do
      socket
      |> assign(:status, :idle)
      |> assign(:in_flight, nil)
      |> reset_tree()
    else
      request = %{
        node: socket.assigns.node.name,
        apps: selected,
        depth: socket.assigns.depth,
        expanded: socket.assigns.expanded_pids
      }

      in_flight = Fetch.start(request)

      socket
      |> assign(:in_flight, in_flight)
      |> assign(:status, :loading)
    end
  end

  defp status_badge_class(:idle), do: "badge-ghost"
  defp status_badge_class(:loading), do: "badge-info"
  defp status_badge_class(:ok), do: "badge-success"
  defp status_badge_class(:partial), do: "badge-warning"
  defp status_badge_class(:error), do: "badge-error"

  defp status_label(:idle), do: "idle"
  defp status_label(:loading), do: "loading"
  defp status_label(:ok), do: "ok"
  defp status_label(:partial), do: "partial"
  defp status_label(:error), do: "error"

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end
end
