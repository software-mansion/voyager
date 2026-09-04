defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Services.SupervisionTree.Remote
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.FormSchemas.SupervisionTreeControls
  alias VoyagerWeb.SupervisionTreeLive.Diff
  alias VoyagerWeb.SupervisionTreeLive.Selection

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :supervision_tree)
      |> assign(:refresh_interval, SupervisionTreeComponents.default_refresh_interval())
      |> assign(:available_apps, AsyncResult.loading())
      |> assign(:available_app_atoms, [])
      |> assign(:selected_apps, MapSet.new())
      |> assign(:depth, SupervisionTreeControls.default_depth())
      |> assign(:include_relations?, SupervisionTreeControls.default_include_relations?())
      |> assign(:params, nil)
      |> assign(:expanded_pids, MapSet.new())
      |> assign(:last_tree_flat, nil)
      |> assign(:last_updated, nil)
      |> assign(:last_relations, %{})
      |> assign(:in_flight, nil)
      |> assign(:errors, [])
      |> assign(:status, :idle)
      |> assign(:refresh_timer, nil)
      |> assign(:selected_node, nil)
      |> assign(:selection_origin, :external)
      |> assign(:pending_reveal, nil)

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
    socket
    |> assign(:params, params)
    |> apply_params(params)
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
        <.async_result :let={available_apps} assign={@available_apps}>
          <:loading>
            <.loading_state
              id="supervision-tree-loading"
              message="Fetching available applications…"
            />
          </:loading>
          <:failed :let={reason}>
            <.error_state id="supervision-tree-error" message={format_error(reason)} />
          </:failed>
          <.live_component
            module={VoyagerWeb.SupervisionTreeLive.Controls}
            id="controls"
            node_name={@session.node_name}
            available_apps={available_apps}
            available_app_atoms={@available_app_atoms}
            selected_apps={@selected_apps}
            current_url={@current_url}
            depth={@depth}
            include_relations?={@include_relations?}
          />
          <SupervisionTreeComponents.errors errors={@errors} />
          <SupervisionTreeComponents.body
            last_updated={@last_updated}
            selected_apps={@selected_apps}
            status={@status}
          />
        </.async_result>
      </div>
      <.live_component
        module={VoyagerWeb.SupervisionTreeLive.DetailsPanel}
        id="details-panel"
        tree_node={@selected_node}
        selection_origin={@selection_origin}
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
    socket
    |> select_node(key)
    |> noreply()
  end

  def handle_event("close-details-panel", _params, socket) do
    socket
    |> assign(:selected_node, nil)
    |> assign(:selection_origin, :external)
    |> assign(:pending_reveal, nil)
    |> noreply()
  end

  @impl true
  def handle_async(:available_apps, {:ok, {:ok, apps}}, socket) do
    available_apps =
      apps
      |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
      |> Enum.sort()

    available_app_atoms = Enum.map(available_apps, &elem(&1, 0))

    socket
    |> assign(:available_apps, AsyncResult.ok(available_apps))
    |> assign(:available_app_atoms, available_app_atoms)
    |> apply_params(socket.assigns.params)
    |> noreply()
  end

  def handle_async(:available_apps, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:status, :error)
    |> assign(
      :available_apps,
      AsyncResult.failed(socket.assigns.available_apps, reason)
    )
    |> noreply()
  end

  def handle_async(:available_apps, {:exit, reason}, socket) do
    socket
    |> assign(:status, :error)
    |> assign(:available_apps, AsyncResult.failed(socket.assigns.available_apps, reason))
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
    |> deselect_removed_nodes(prev_flat)
    |> push_event("tree-data", payload)
    |> maybe_reveal_pending()
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

  def handle_info({:select_link, identifier}, socket) do
    socket
    |> select_identifier(identifier)
    |> noreply()
  end

  def handle_info({:restore_details_node, node}, socket) do
    node = Selection.lookup(socket.assigns.last_tree_flat, node.key) || node

    socket
    |> assign(:pending_reveal, nil)
    |> put_selected_node(node, focus: true, origin: :restore)
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
    node = socket.assigns.session.node

    start_async(socket, :available_apps, fn -> Remote.list_running_applications(node) end)
  end

  defp apply_params(socket, nil), do: socket

  defp apply_params(socket, params) do
    params
    |> params_to_attrs()
    |> SupervisionTreeControls.changeset(socket.assigns.available_app_atoms)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok,
       %SupervisionTreeControls{apps: apps, depth: depth, include_relations?: include_relations?}} ->
        new_selected = MapSet.new(apps)

        apps_changed? = new_selected != socket.assigns.selected_apps
        depth_changed? = depth != socket.assigns.depth
        relations_changed? = include_relations? != socket.assigns.include_relations?

        socket =
          socket
          |> assign(:selected_apps, new_selected)
          |> assign(:depth, depth)
          |> assign(:include_relations?, include_relations?)
          |> assign_available_apps(new_selected)
          |> maybe_reset_expanded_pids(depth_changed?)

        if connected?(socket) and (apps_changed? or depth_changed? or relations_changed?) do
          socket
          |> reset_tree()
          |> request_fetch()
        else
          socket
        end

      {:error, _} ->
        socket
    end
  end

  defp assign_available_apps(socket, new_selected) do
    case socket.assigns.available_apps do
      %AsyncResult{ok?: true, result: available_apps} when not is_nil(available_apps) ->
        {selected_apps, rest_apps} =
          Enum.split_with(available_apps, fn {app, _} ->
            MapSet.member?(new_selected, app)
          end)

        assign(socket, :available_apps, AsyncResult.ok(selected_apps ++ Enum.sort(rest_apps)))

      %AsyncResult{} ->
        socket
    end
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
      |> assign(:last_updated, nil)
      |> reset_tree()
    else
      request = %{
        node: socket.assigns.session.node,
        apps: selected,
        depth: socket.assigns.depth,
        expanded: socket.assigns.expanded_pids,
        include_relations?: socket.assigns.include_relations?
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

  defp select_node(socket, key) when key in [nil, ""] do
    socket
    |> push_event("path-highlight", %{path: []})
    |> assign(:selected_node, nil)
    |> assign(:selection_origin, :external)
    |> assign(:pending_reveal, nil)
  end

  defp select_node(socket, key) do
    case Selection.lookup(socket.assigns.last_tree_flat, key) do
      nil ->
        socket

      node ->
        socket
        |> assign(:pending_reveal, nil)
        |> put_selected_node(node)
    end
  end

  defp select_identifier(socket, identifier) do
    resolved =
      Selection.resolve_jump(
        socket.assigns.last_tree_flat,
        identifier,
        socket.assigns.selected_node,
        socket.assigns.expanded_pids
      )

    case resolved do
      :ignore ->
        socket

      {:select, node} ->
        put_selected_node(socket, node, focus: true, origin: :link)

      {:select_placeholder, node} ->
        put_selected_node(socket, node, origin: :link)

      {:expand_and_reveal, placeholder, stub} ->
        socket
        |> put_selected_node(placeholder, origin: :link)
        |> assign(:expanded_pids, MapSet.put(socket.assigns.expanded_pids, stub.pid))
        |> assign(:pending_reveal, identifier)
        |> request_fetch(:toggle_expand)
    end
  end

  defp maybe_reveal_pending(socket) do
    case socket.assigns[:pending_reveal] do
      nil ->
        socket

      identifier ->
        socket = assign(socket, :pending_reveal, nil)

        case Selection.lookup(socket.assigns.last_tree_flat, TreeNode.key(identifier)) do
          nil -> socket
          node -> put_selected_node(socket, node, focus: true, origin: :link)
        end
    end
  end

  defp put_selected_node(socket, node, opts \\ [])
  defp put_selected_node(socket, nil, _opts), do: socket

  defp put_selected_node(socket, node, opts) do
    flat = socket.assigns.last_tree_flat
    in_tree? = Selection.lookup(flat, node.key) != nil
    path = if in_tree?, do: Selection.path_to_root(flat, node.key), else: []
    focus? = Keyword.get(opts, :focus, false)

    socket = push_event(socket, "path-highlight", %{path: path})

    socket =
      if focus? and in_tree? do
        push_event(socket, "focus-node", %{key: node.key})
      else
        socket
      end

    socket
    |> assign(:selected_node, node)
    |> assign(:selection_origin, Keyword.get(opts, :origin, :external))
  end

  # Drop a graph-backed selection when its key disappears from the tree. Keep
  # selections opened from a PID link that were never in the graph.
  defp deselect_removed_nodes(socket, prev_flat) do
    case socket.assigns.selected_node do
      %{key: key} ->
        new_flat = socket.assigns.last_tree_flat

        cond do
          is_map(new_flat) and Map.has_key?(new_flat, key) ->
            assign(socket, :selected_node, Map.fetch!(new_flat, key))

          is_map(prev_flat) and Map.has_key?(prev_flat, key) ->
            socket
            |> assign(:selected_node, nil)
            |> assign(:pending_reveal, nil)

          true ->
            socket
        end

      _ ->
        socket
    end
  end

  defp parse_pid(pid_str) when is_binary(pid_str) do
    pid_str |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp parse_pid(_), do: nil

  defp reset_tree(socket),
    do:
      assign(socket,
        last_tree_flat: nil,
        last_relations: %{},
        selected_node: nil,
        selection_origin: :external,
        pending_reveal: nil
      )

  defp params_to_attrs(params) do
    case Map.get(params, "apps") do
      value when is_binary(value) ->
        Map.put(params, "apps", String.split(value, ",", trim: true))

      _ ->
        params
    end
  end

  defp format_error(:timeout), do: "Timed out while fetching available applications."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:erpc, _reason}),
    do: "RPC call failed while fetching available applications."

  defp format_error(_), do: "Failed to fetch available applications."
end
