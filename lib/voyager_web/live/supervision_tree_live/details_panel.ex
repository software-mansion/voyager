defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Side panel that displays details for a selected node in the supervision tree.

  The parent LiveView owns the selection: it passes the selected `TreeNode` (or
  `nil` to close the panel) and must handle the `"close-details-panel"` event
  the close button emits.

  ## Example

      def handle_event("close-details-panel", _params, socket) do
        socket
        |> assign(:tree_node, nil)
        |> noreply()
      end
  """

  use VoyagerWeb, :live_component

  import VoyagerWeb.Components.DetailsPanelComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.SupervisionTree.TreeNode

  require Logger

  # No point fetching more links than the panel can ever render.
  @links_limit max_expanded_links()

  @impl true
  def mount(socket) do
    socket
    |> assign(:node, nil)
    |> assign(:remote_node, nil)
    |> assign(:open?, false)
    |> assign(:links_expanded?, false)
    |> assign(:node_info, AsyncResult.loading())
    |> assign(:links, AsyncResult.loading())
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

  def handle_event("refresh-node-info", _params, socket) do
    socket
    |> maybe_fetch_node_info(socket.assigns.node)
    |> maybe_fetch_links(socket.assigns.node)
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
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <.node_type_label node_type={@node.type} />
            <.node_label panel_id={@id} node={@node} />
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <.refresh_button
              :if={is_pid(@node.pid)}
              panel_id={@id}
              myself={@myself}
              loading?={@node_info.loading}
            />
            <.close_button panel_id={@id} />
          </div>
        </div>
        <%!-- Scrollable body --%>
        <.body
          panel_id={@id}
          info={@node_info}
          links_info={@links}
          node={@node}
          links_expanded?={@links_expanded?}
          myself={@myself}
        />
        <.show_more_button panel_id={@id} />
      <% end %>
    </aside>
    """
  end

  defp maybe_assign_node(socket, nil), do: assign(socket, :open?, false)

  defp maybe_assign_node(socket, node) do
    node_changed? = node_changed?(socket, node)

    socket =
      socket
      |> assign(:open?, true)
      |> assign(:node, node)
      |> maybe_fetch_node_info(node)
      |> maybe_fetch_links(node)

    if node_changed? do
      assign(socket, :links_expanded?, false)
    else
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

  defp maybe_fetch_links(socket, %TreeNode{pid: pid}) when is_pid(pid) do
    remote_node = socket.assigns.remote_node

    socket
    |> assign(:links, AsyncResult.loading())
    |> assign_async(:links, fn -> fetch_links_result(remote_node, pid) end)
  end

  defp maybe_fetch_links(socket, _node) do
    assign(socket, :links, AsyncResult.ok(nil))
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
        {:ok, %{node_info: Map.put(info, :label, fetch_label(remote_node, pid))}}

      {:error, reason} ->
        Logger.warning(
          "Failed to load node info for #{inspect(remote_node)}/#{inspect(pid)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The label is an arbitrary term, so it needs the agent's remote truncation and
  # cannot ride along in the cheap `fetch/2` payload. A node without the agent
  # loaded simply has no label to show -- it must not fail the whole overview.
  defp fetch_label(remote_node, pid) do
    case ProcessInfo.fetch_label(remote_node, pid) do
      {:ok, %{term: term}} ->
        term

      {:error, reason} ->
        Logger.warning(
          "Failed to load label for #{inspect(remote_node)}/#{inspect(pid)}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp fetch_links_result(remote_node, pid) do
    case ProcessInfo.fetch_links(remote_node, pid, @links_limit) do
      {:ok, bounded} ->
        {:ok, %{links: bounded}}

      {:error, reason} ->
        Logger.warning(
          "Failed to load links for #{inspect(remote_node)}/#{inspect(pid)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
