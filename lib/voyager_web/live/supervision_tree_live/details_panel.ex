defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Details for the selected supervision tree node. The parent owns the selection;
  this component owns the Back history, reset unless `keep_history?` is set.
  """

  use VoyagerWeb, :live_component

  import VoyagerWeb.Components.DetailsPanelComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.ProcessInfoLive.Query

  require Logger

  # No point fetching more relations than the panel can ever render.
  @relations_limit max_expanded_relations()
  @relation_names ~w(links monitors monitored_by)

  @impl true
  def mount(socket) do
    socket
    |> assign(:node, nil)
    |> assign(:remote_node, nil)
    |> assign(:open?, false)
    |> assign(:expanded_relations, MapSet.new())
    |> assign(:selection_history, [])
    |> assign(:node_info, AsyncResult.loading())
    |> assign(:relations, AsyncResult.loading())
    |> ok()
  end

  @impl true
  def update(
        %{
          id: id,
          tree_node: tree_node,
          remote_node: remote_node,
          node_name: node_name,
          keep_history?: keep_history?,
          revealing?: revealing?
        },
        socket
      ) do
    socket
    |> assign(:id, id)
    |> assign(:remote_node, remote_node)
    |> assign(:node_name, node_name)
    |> assign(:revealing?, revealing?)
    |> maybe_assign_node(tree_node, keep_history?)
    |> ok()
  end

  @impl true
  def handle_event("toggle-relation", %{"relation" => relation}, socket)
      when relation in @relation_names do
    relation = String.to_existing_atom(relation)
    expanded = socket.assigns.expanded_relations

    expanded =
      if MapSet.member?(expanded, relation),
        do: MapSet.delete(expanded, relation),
        else: MapSet.put(expanded, relation)

    socket
    |> assign(:expanded_relations, expanded)
    |> noreply()
  end

  def handle_event("toggle-relation", _, socket), do: noreply(socket)

  def handle_event("select-relation", %{"key" => key}, socket) do
    remote_node = socket.assigns.remote_node

    case relation_by_key(socket.assigns.relations, key, remote_node) ||
           info_pid_by_key(socket, key) do
      nil ->
        noreply(socket)

      {_kind, {name, _node}} ->
        socket
        |> start_async(:resolve_name, fn ->
          Query.whereis(remote_node, name, Query.default_timeout())
        end)
        |> noreply()

      identifier ->
        socket
        |> select_link(identifier)
        |> noreply()
    end
  end

  def handle_event("back-details-node", _params, socket) do
    case socket.assigns.selection_history do
      [prev | rest] ->
        send(self(), {:restore_details_node, prev})

        socket
        |> assign(:selection_history, rest)
        |> noreply()

      [] ->
        noreply(socket)
    end
  end

  def handle_event("refresh-node-info", _params, socket) do
    socket
    |> fetch_details(true)
    |> noreply()
  end

  @impl true
  def handle_async(:resolve_name, {:ok, {:ok, target, _elapsed_ms}}, socket) do
    socket
    |> select_link(target)
    |> noreply()
  end

  def handle_async(:resolve_name, result, socket) do
    Logger.warning("Failed to resolve a monitored name: #{inspect(result)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id={@id}
      phx-hook="DetailsPanelResize"
      inert={not @open?}
      class={[
        "details-panel",
        "border-base-200 bg-base-100 absolute inset-y-0 right-0 z-40 flex w-full flex-col border-l p-2 shadow-2xl transition-transform duration-300 ease-in-out",
        if(@open?, do: "translate-x-0", else: "translate-x-full")
      ]}
    >
      <.resize_handle panel_id={@id} open?={@open?} />
      <%= if @node do %>
        <%!-- Header --%>
        <div class="border-base-200 flex items-start gap-3 border-b px-5 py-4">
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <.node_type_label
              panel_id={@id}
              node_type={@node.type}
              off_tree?={@node.placeholder?}
              off_node={off_node(@node, @remote_node)}
            />
            <.node_label panel_id={@id} node={@node} />
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <.back_button
              :if={@selection_history != []}
              panel_id={@id}
              on_back="back-details-node"
              target={@myself}
            />
            <.refresh_button
              :if={is_pid(@node.pid)}
              panel_id={@id}
              on_refresh="refresh-node-info"
              target={@myself}
              loading?={@node_info.loading}
            />
            <.close_button panel_id={@id} on_close="close-details-panel" />
          </div>
        </div>
        <%!-- Scrollable body --%>
        <.body
          panel_id={@id}
          info={@node_info}
          relations_info={@relations}
          node={@node}
          expanded_relations={@expanded_relations}
          on_select="select-relation"
          on_toggle_relation="toggle-relation"
          target={@myself}
          remote_node={@remote_node}
          chips_disabled?={@revealing?}
        />
        <.show_more_button
          panel_id={@id}
          href={process_href(@node.pid, @remote_node, @node_name)}
        />
      <% end %>
    </aside>
    """
  end

  # Only pids living on the inspected node have a process page.
  defp process_href(pid, remote_node, node_name)
       when is_pid(pid) and node(pid) == remote_node and is_binary(node_name) do
    ~p"/node/#{node_name}/processes/#{Formatters.format_pid(pid)}"
  end

  defp process_href(_pid, _remote_node, _node_name), do: nil

  defp maybe_assign_node(socket, nil, _keep_history?) do
    socket
    |> assign(:open?, false)
    |> assign(:selection_history, [])
  end

  # A tree refresh of the shown process keeps its data on screen until the refetch lands.
  defp maybe_assign_node(socket, node, keep_history?) do
    history = if keep_history?, do: socket.assigns.selection_history, else: []
    showing? = socket.assigns.open? and same_process?(socket.assigns.node, node)
    expanded = if showing?, do: socket.assigns.expanded_relations, else: MapSet.new()

    socket
    |> assign(open?: true, node: node, selection_history: history, expanded_relations: expanded)
    |> fetch_details(not showing?)
  end

  defp off_node(%TreeNode{pid: pid}, remote_node) when is_pid(pid) and node(pid) != remote_node,
    do: node(pid)

  defp off_node(_node, _remote_node), do: nil

  defp select_link(socket, identifier) do
    send(self(), {:select_link, identifier})
    push_history(socket)
  end

  defp push_history(%{assigns: %{node: %TreeNode{} = node}} = socket),
    do: assign(socket, :selection_history, [node | socket.assigns.selection_history])

  defp push_history(socket), do: socket

  defp fetch_details(%{assigns: %{node: %TreeNode{pid: pid}}} = socket, reset?)
       when is_pid(pid) do
    remote_node = socket.assigns.remote_node
    timeout = Query.default_timeout()

    socket
    |> assign_async(:node_info, fn -> fetch_node_info(remote_node, pid, timeout) end,
      reset: reset?
    )
    |> assign_async(:relations, fn -> fetch_relations(remote_node, pid, timeout) end,
      reset: reset?
    )
  end

  # Nothing to fetch for apps, ports and references: settle the async assigns so
  # the body never shows a load state it will not leave.
  defp fetch_details(socket, _reset?) do
    assign(socket, node_info: AsyncResult.ok(nil), relations: AsyncResult.ok(nil))
  end

  defp same_process?(%TreeNode{pid: pid}, %TreeNode{pid: pid}) when is_pid(pid), do: true
  defp same_process?(_previous, _node), do: false

  defp fetch_node_info(remote_node, pid, timeout) do
    with {:ok, info, _elapsed_ms} <- Query.overview(remote_node, pid, timeout) do
      {:ok, %{node_info: info}}
    end
  end

  defp fetch_relations(remote_node, pid, timeout) do
    with {:ok, relations, _elapsed_ms} <-
           Query.relations(remote_node, pid, @relations_limit, timeout) do
      monitors = Enum.map(relations.monitors.items, &monitor_target/1)
      {:ok, %{relations: put_in(relations.monitors.items, monitors)}}
    end
  end

  defp monitor_target({_kind, target}) when is_pid(target) or is_port(target), do: target
  defp monitor_target(monitor), do: monitor

  defp relation_by_key(%AsyncResult{ok?: true, result: relations}, key, remote_node)
       when is_map(relations) do
    relations
    |> Map.values()
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&(selectable_relation?(&1, remote_node) and relation_key(&1) == key))
  end

  defp relation_by_key(_, _, _), do: nil

  defp info_pid_by_key(
         %{assigns: %{node_info: %AsyncResult{ok?: true, result: info}}} = socket,
         key
       )
       when is_map(info) do
    [:parent, :group_leader]
    |> Enum.map(&linkable_pid(&1, info, socket.assigns.remote_node))
    |> Enum.find(&(&1 && TreeNode.key(&1) == key))
  end

  defp info_pid_by_key(_socket, _key), do: nil
end
