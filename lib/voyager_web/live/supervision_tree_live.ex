defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Services.SupervisionTree.Remote
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.FormSchemas.SupervisionTreeControls
  alias VoyagerWeb.SupervisionTreeLive.Diff

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
      |> assign(:selection_history, [])
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
        remote_node={@session.node}
        can_go_back?={@selection_history != []}
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
    |> assign(:selection_history, [])
    |> assign(:pending_reveal, nil)
    |> noreply()
  end

  def handle_event("back-details-node", _params, socket) do
    socket
    |> pop_selection_history()
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
    |> assign(:selection_history, [])
    |> assign(:pending_reveal, nil)
  end

  defp select_node(socket, key) do
    case lookup_tree_node(socket, key) do
      nil ->
        socket

      node ->
        socket
        |> assign(:selection_history, [])
        |> assign(:pending_reveal, nil)
        |> put_selected_node(node)
    end
  end

  defp select_identifier(socket, identifier) do
    key = TreeNode.key(identifier)
    in_tree = lookup_tree_node(socket, key)

    cond do
      is_nil(in_tree) and is_nil(tree_node_from_identifier(identifier)) ->
        socket

      in_tree && socket.assigns.selected_node &&
          socket.assigns.selected_node.key == in_tree.key ->
        put_selected_node(socket, in_tree, focus: true)

      in_tree ->
        socket
        |> push_selection_history()
        |> put_selected_node(in_tree, focus: true)

      true ->
        socket
        |> push_selection_history()
        |> put_selected_node(tree_node_from_identifier(identifier))
        |> maybe_expand_to_reveal(identifier)
    end
  end

  defp push_selection_history(socket) do
    case socket.assigns.selected_node do
      nil -> socket
      node -> assign(socket, :selection_history, [node | socket.assigns.selection_history])
    end
  end

  defp pop_selection_history(socket) do
    case socket.assigns.selection_history do
      [prev | rest] ->
        node = lookup_tree_node(socket, prev.key) || prev

        socket
        |> assign(:selection_history, rest)
        |> assign(:pending_reveal, nil)
        |> put_selected_node(node, focus: true)

      [] ->
        socket
    end
  end

  # When a PID-link isn't in the loaded walk, expand one already-visible stub
  # supervisor (the node we came from, or a stub that lists this pid in its
  # links). That is the same work as a manual +/- expand: one `which_children`
  # plus hydrate for that supervisor's direct children.
  defp maybe_expand_to_reveal(socket, identifier) when is_pid(identifier) do
    stub = stub_to_expand(socket, identifier)

    cond do
      is_nil(stub) ->
        socket

      MapSet.member?(socket.assigns.expanded_pids, stub.pid) ->
        socket

      true ->
        socket
        |> assign(:expanded_pids, MapSet.put(socket.assigns.expanded_pids, stub.pid))
        |> assign(:pending_reveal, identifier)
        |> request_fetch(:toggle_expand)
    end
  end

  defp maybe_expand_to_reveal(socket, _identifier), do: socket

  defp stub_to_expand(socket, identifier) do
    prev =
      case socket.assigns.selection_history do
        [node | _] -> node
        _ -> nil
      end

    if expandable_stub?(prev) do
      prev
    else
      find_stub_linking_to(socket.assigns.last_tree_flat, identifier)
    end
  end

  defp expandable_stub?(%TreeNode{
         type: type,
         pid: pid,
         children_keys: :not_loaded,
         child_count: n
       })
       when type in [:supervisor, :app] and is_pid(pid) and is_integer(n) and n > 0,
       do: true

  defp expandable_stub?(_), do: false

  defp find_stub_linking_to(flat, identifier) when is_map(flat) do
    Enum.find_value(flat, fn
      {_key, %TreeNode{} = node} ->
        if expandable_stub?(node) and linked_to?(node, identifier), do: node

      _ ->
        nil
    end)
  end

  defp find_stub_linking_to(_flat, _identifier), do: nil

  defp linked_to?(%TreeNode{info: %{links: links}}, identifier) when is_list(links),
    do: identifier in links

  defp linked_to?(_node, _identifier), do: false

  defp maybe_reveal_pending(socket) do
    case socket.assigns[:pending_reveal] do
      nil ->
        socket

      identifier ->
        socket = assign(socket, :pending_reveal, nil)

        case lookup_tree_node(socket, TreeNode.key(identifier)) do
          nil -> socket
          node -> put_selected_node(socket, node, focus: true)
        end
    end
  end

  defp put_selected_node(socket, node, opts \\ [])
  defp put_selected_node(socket, nil, _opts), do: socket

  defp put_selected_node(socket, node, opts) do
    in_tree? = match?(%TreeNode{}, lookup_tree_node(socket, node.key))
    path = if in_tree?, do: walk_to_root(socket.assigns.last_tree_flat, node.key), else: []
    focus? = Keyword.get(opts, :focus, false)

    socket = push_event(socket, "path-highlight", %{path: path})

    socket =
      if focus? and in_tree? do
        push_event(socket, "focus-node", %{key: node.key})
      else
        socket
      end

    assign(socket, :selected_node, node)
  end

  defp lookup_tree_node(socket, key) do
    case socket.assigns.last_tree_flat do
      %{^key => %TreeNode{} = node} ->
        node

      flat when is_map(flat) ->
        find_node_by_pid_key(flat, key)

      _ ->
        nil
    end
  end

  # App wrappers are keyed `app:<name>` while PID-links look up `<X.Y.Z>`.
  # Fall back to matching the live pid so those nodes still highlight.
  defp find_node_by_pid_key(flat, key) do
    matches =
      Enum.filter(flat, fn
        {_k, %TreeNode{pid: pid}} when is_pid(pid) -> TreeNode.key(pid) == key
        _ -> false
      end)

    nodes = Enum.map(matches, &elem(&1, 1))
    Enum.find(nodes, &(&1.type == :app)) || List.first(nodes)
  end

  defp tree_node_from_identifier(pid) when is_pid(pid) do
    %TreeNode{key: TreeNode.key(pid), pid: pid, name: pid, type: :process}
  end

  defp tree_node_from_identifier(port) when is_port(port) do
    %TreeNode{key: TreeNode.key(port), name: port, type: :port}
  end

  defp tree_node_from_identifier(_), do: nil

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
            |> assign(:selection_history, [])
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
        selection_history: [],
        pending_reveal: nil
      )

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
