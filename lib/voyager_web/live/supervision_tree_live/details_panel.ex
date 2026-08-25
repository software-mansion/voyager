defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Side panel that displays details for a selected node in the supervision tree.

  The parent LiveView owns the current selection (graph highlight / focus) and
  passes the selected `TreeNode` (or `nil` to close). This component owns the
  in-panel navigation history: link clicks push the current node, Back pops it,
  and a parent-driven selection (graph click, close) resets the stack.

  Link / back notify the parent via `send/2` (`{:select_link, id}` /
  `{:restore_details_node, node}`). Close has no `phx-target`, so it is handled
  on the parent as `"close-details-panel"`.
  """

  use VoyagerWeb, :live_component

  import VoyagerWeb.Components.DetailsPanelComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.SupervisionTree.TreeNode

  require Logger

  @impl true
  def mount(socket) do
    socket
    |> assign(:node, nil)
    |> assign(:remote_node, nil)
    |> assign(:open?, false)
    |> assign(:links_expanded?, false)
    |> assign(:selection_history, [])
    |> assign(:awaiting_parent_selection?, false)
    |> assign(:node_info, AsyncResult.loading())
    |> ok()
  end

  @impl true
  def update(%{id: id, tree_node: tree_node, remote_node: remote_node}, socket) do
    socket
    |> assign(:id, id)
    |> assign(:remote_node, remote_node)
    |> maybe_assign_node(tree_node)
    |> ok()
  end

  @impl true
  def handle_event("toggle-links", _params, socket) do
    socket
    |> assign(:links_expanded?, not socket.assigns.links_expanded?)
    |> noreply()
  end

  def handle_event("select-link", %{"key" => key}, socket) do
    case link_by_key(socket.assigns.node_info, key) do
      nil ->
        noreply(socket)

      identifier ->
        send(self(), {:select_link, identifier})

        socket
        |> push_history(identifier)
        |> assign(:awaiting_parent_selection?, true)
        |> noreply()
    end
  end

  def handle_event("back-details-node", _params, socket) do
    case socket.assigns.selection_history do
      [prev | rest] ->
        send(self(), {:restore_details_node, prev})

        socket
        |> assign(:selection_history, rest)
        |> assign(:awaiting_parent_selection?, true)
        |> noreply()

      [] ->
        noreply(socket)
    end
  end

  def handle_event("refresh-node-info", _params, socket) do
    socket
    |> maybe_fetch_node_info(socket.assigns.node)
    |> noreply()
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
          <.back_button
            :if={@selection_history != []}
            panel_id={@id}
            on_back="back-details-node"
            target={@myself}
          />
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <.node_type_label node_type={@node.type} />
            <.node_label panel_id={@id} node={@node} />
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
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
          node={@node}
          links_expanded?={@links_expanded?}
          on_select="select-link"
          on_toggle_links="toggle-links"
          target={@myself}
        />
        <.show_more_button panel_id={@id} />
      <% end %>
    </aside>
    """
  end

  defp maybe_assign_node(socket, nil) do
    socket
    |> assign(:open?, false)
    |> assign(:selection_history, [])
    |> assign(:awaiting_parent_selection?, false)
  end

  defp maybe_assign_node(socket, node) do
    changed? = node_changed?(socket, node)
    awaiting? = socket.assigns.awaiting_parent_selection?

    socket
    |> assign(:open?, true)
    |> assign(:node, node)
    |> assign(:awaiting_parent_selection?, false)
    |> then(fn socket ->
      cond do
        awaiting? -> socket
        changed? -> assign(socket, :selection_history, [])
        true -> socket
      end
    end)
    |> then(fn socket ->
      if changed?, do: assign(socket, :links_expanded?, false), else: socket
    end)
    |> maybe_fetch_node_info(node)
  end

  defp push_history(socket, identifier) do
    case socket.assigns.node do
      %TreeNode{key: key} = node ->
        if key == TreeNode.key(identifier) do
          socket
        else
          assign(socket, :selection_history, [node | socket.assigns.selection_history])
        end

      _ ->
        socket
    end
  end

  defp maybe_fetch_node_info(socket, %TreeNode{pid: pid}) when is_pid(pid) do
    remote_node = socket.assigns.remote_node

    socket
    |> assign(:node_info, AsyncResult.loading())
    |> assign_async(:node_info, fn -> fetch_node_info(remote_node, pid) end)
  end

  # Nothing to fetch for apps, ports and references: settle the async assign so
  # the body never shows a load state it will not leave.
  defp maybe_fetch_node_info(socket, _node) do
    assign(socket, :node_info, AsyncResult.ok(nil))
  end

  defp node_changed?(socket, node) do
    case socket.assigns[:node] do
      %TreeNode{key: key} -> key != node.key
      _ -> true
    end
  end

  defp fetch_node_info(remote_node, pid) do
    case ProcessInfo.fetch(remote_node, pid) do
      {:ok, info} ->
        {:ok, %{node_info: info}}

      {:error, reason} ->
        Logger.warning(
          "Failed to load node info for #{inspect(remote_node)}/#{inspect(pid)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp link_by_key(%AsyncResult{ok?: true, result: %{links: links}}, key) when is_list(links) do
    Enum.find(links, &(TreeNode.key(&1) == key))
  end

  defp link_by_key(_, _), do: nil
end
