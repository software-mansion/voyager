defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Services.SupervisionTree.Remote
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.FormSchemas.SupervisionTreeControls
  alias VoyagerWeb.SupervisionTreeLive.Diff

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :supervision_tree)
      |> assign(:refresh_interval, SupervisionTreeComponents.default_refresh_interval())
      |> assign(:available_apps, [])
      |> assign(:available_app_atoms, [])
      |> assign(:selected_apps, MapSet.new())
      |> assign(:depth, SupervisionTreeControls.default_depth())
      |> assign(:expanded_pids, MapSet.new())
      |> assign(:last_tree_flat, nil)
      |> assign(:last_updated, nil)
      |> assign(:last_relations, %{})
      |> assign(:in_flight, nil)
      |> assign(:errors, [])
      |> assign(:status, :idle)
      |> assign(:refresh_timer, nil)
      |> assign(:selected_node, nil)

    if connected?(socket) do
      socket
      |> assign_applications()
      |> start_timer()
    else
      socket
    end
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params
    |> params_to_attrs()
    |> SupervisionTreeControls.changeset(socket.assigns.available_app_atoms)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, %SupervisionTreeControls{apps: apps, depth: depth}} ->
        new_selected = MapSet.new(apps)

        apps_changed? = new_selected != socket.assigns.selected_apps
        depth_changed? = depth != socket.assigns.depth

        socket =
          socket
          |> assign(:selected_apps, new_selected)
          |> assign(:depth, depth)
          |> assign_available_apps(new_selected)
          |> maybe_reset_expanded_pids(depth_changed?)

        if connected?(socket) and (apps_changed? or depth_changed?) do
          socket
          |> reset_tree()
          |> request_fetch()
        else
          socket
        end

      {:error, changeset} ->
        assign(socket, :apps_form, to_form(changeset, as: :tree_controls))
    end
    |> noreply()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="supervision-tree" class="relative flex h-full overflow-x-hidden">
      <div class="flex h-full flex-1 flex-col gap-4 overflow-hidden p-6 sm:p-8">
        <SupervisionTreeComponents.header
          node_name={@session.node_name}
          status={@status}
          last_updated={@last_updated}
          refresh_interval={@refresh_interval}
        />
        <.live_component
          module={VoyagerWeb.SupervisionTreeLive.Controls}
          id="controls"
          node_name={@session.node_name}
          available_apps={@available_apps}
          available_app_atoms={@available_app_atoms}
          selected_apps={@selected_apps}
          depth={@depth}
        />
        <SupervisionTreeComponents.errors errors={@errors} />
        <SupervisionTreeComponents.body selected_apps={@selected_apps} status={@status} />
      </div>
      <.live_component
        module={VoyagerWeb.SupervisionTreeLive.DetailsPanel}
        id="process-panel"
        node={@selected_node}
        remote_node={@session.node}
      />
    </div>
    """
  end

  @impl true
  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> stop_timer()
    |> start_timer()
    |> noreply()
  end

  def handle_event("refresh_now", _params, socket) do
    socket
    |> request_fetch(:manual_refresh)
    |> noreply()
  end

  def handle_event("dismiss_errors", _params, socket) do
    socket
    |> assign(:errors, [])
    |> noreply()
  end

  def handle_event("toggle-expand", %{"pid" => pid_str}, socket) do
    {expanded, newly_expanded?} =
      toggle_expand(socket, pid_str)

    socket = assign(socket, :expanded_pids, expanded)

    if newly_expanded? do
      request_fetch(socket, :toggle_expand)
    else
      socket
    end
    |> noreply()
  end

  def handle_event("select-node", %{"key" => key}, socket) do
    path = walk_to_root(socket.assigns.last_tree_flat, key)

    socket
    |> push_event("path-highlight", %{path: path})
    |> assign_selected_node(key)
    |> noreply()
  end

  def handle_event("close-details-panel", _params, socket) do
    socket
    |> assign(:selected_node, nil)
    |> noreply()
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> stop_timer()
      |> start_timer()

    if MapSet.size(socket.assigns.selected_apps) > 0 and is_nil(socket.assigns.in_flight) do
      request_fetch(socket, :auto_refresh)
    else
      socket
    end
    |> noreply()
  end

  def handle_info(
        {ref, {status, result, errors}},
        %{assigns: %{in_flight: %{ref: ref}}} = socket
      ) do
    stop_timer(socket)

    Process.demonitor(ref, [:flush])

    new_flat = result.nodes
    new_edges = result.edges
    prev_flat = socket.assigns.last_tree_flat
    prev_edges = socket.assigns.last_relations

    payload =
      case prev_flat do
        nil ->
          %{
            kind: "full",
            request_type: socket.private.request_type,
            nodes: new_flat,
            edges: new_edges
          }

        prev ->
          node_diff = Diff.diff(prev, new_flat)
          edge_diff = Diff.diff_relations(prev_edges, new_edges)

          node_diff
          |> Map.merge(edge_diff)
          |> Map.merge(%{kind: "delta", request_type: socket.private.request_type})
      end

    socket
    |> assign(:errors, errors)
    |> assign(:status, status)
    |> assign(:in_flight, nil)
    |> assign(:last_tree_flat, new_flat)
    |> assign(:last_relations, new_edges)
    |> assign(:last_updated, DateTime.utc_now())
    |> push_event("tree-data", payload)
    |> start_timer()
    |> noreply()
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{in_flight: %{ref: ref}}} = socket
      ) do
    socket
    |> stop_timer()
    |> start_timer()
    |> assign(:in_flight, nil)
    |> assign(:status, :error)
    |> assign(:errors, socket.assigns.errors ++ [{:fetch, reason}])
    |> reset_tree()
    |> noreply()
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:in_flight] do
      Fetch.cancel(socket.assigns.in_flight)
    end

    stop_timer(socket)

    :ok
  end

  defp assign_applications(socket) do
    case Remote.list_running_applications(socket.assigns.session.node) do
      {:ok, apps} ->
        available =
          apps
          |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
          |> Enum.sort()

        socket
        |> assign(:available_apps, available)
        |> assign(:available_app_atoms, Enum.map(available, &elem(&1, 0)))

      {:error, reason} ->
        socket
        |> assign(:status, :error)
        |> assign(:errors, [{:list_running_applications, socket.assigns.session.node, reason}])
    end
  end

  defp assign_available_apps(socket, new_selected) do
    {selected_apps, rest_apps} =
      Enum.split_with(socket.assigns.available_apps, fn {app, _} ->
        MapSet.member?(new_selected, app)
      end)

    assign(socket, :available_apps, selected_apps ++ Enum.sort(rest_apps))
  end

  defp maybe_reset_expanded_pids(socket, true), do: assign(socket, :expanded_pids, MapSet.new())
  defp maybe_reset_expanded_pids(socket, false), do: socket

  defp request_fetch(socket, type \\ :initial) do
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
        node: socket.assigns.session.node,
        apps: selected,
        depth: socket.assigns.depth,
        expanded: socket.assigns.expanded_pids
      }

      in_flight = Fetch.start(request)

      socket
      |> assign(:in_flight, in_flight)
      |> assign(:status, :loading)
      |> put_private(:request_type, type)
    end
  end

  defp stop_timer(socket) do
    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    socket
  end

  defp start_timer(socket) do
    case socket.assigns.refresh_interval do
      nil ->
        socket

      interval ->
        timer = Process.send_after(self(), :refresh, interval)
        assign(socket, :refresh_timer, timer)
    end
  end

  defp parse_interval("off"), do: nil

  defp parse_interval(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp toggle_expand(socket, pid_str) do
    expanded = socket.assigns.expanded_pids
    pid = parse_pid(pid_str)

    cond do
      is_nil(pid) ->
        {expanded, false}

      MapSet.member?(expanded, pid) ->
        {MapSet.delete(expanded, pid), false}

      true ->
        {MapSet.put(expanded, pid), true}
    end
  end

  defp assign_selected_node(socket, key) do
    selected_node = socket.assigns.last_tree_flat && Map.get(socket.assigns.last_tree_flat, key)
    assign(socket, :selected_node, selected_node)
  end

  defp parse_pid(pid_str) when is_binary(pid_str) do
    pid_str |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp parse_pid(_), do: nil

  defp reset_tree(socket), do: assign(socket, last_tree_flat: nil, last_relations: %{})

  defp walk_to_root(_flat, ""), do: []
  defp walk_to_root(nil, _key), do: []

  defp walk_to_root(flat, key) when is_map(flat) do
    walk_to_root(flat, key, [])
  end

  defp walk_to_root(_flat, nil, acc), do: Enum.reverse(acc)

  defp walk_to_root(flat, key, acc) do
    case Map.fetch(flat, key) do
      :error -> Enum.reverse(acc)
      {:ok, node} -> walk_to_root(flat, node.parent_key, [key | acc])
    end
  end

  defp params_to_attrs(params) do
    apps =
      case params["apps"] do
        value when is_binary(value) -> String.split(value, ",", trim: true)
        _ -> []
      end

    depth = params["depth"] || SupervisionTreeControls.default_depth()

    %{"apps" => apps, "depth" => depth}
  end
end
