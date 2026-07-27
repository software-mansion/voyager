defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Side panel that displays details for a selected node in the supervision tree.
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
    |> assign(:open, false)
    |> assign(:links_expanded?, false)
    |> assign(:node_info, AsyncResult.loading())
    |> ok()
  end

  @impl true
  def update(%{id: id, node: node, remote_node: remote_node}, socket) do
    socket
    |> assign(:id, id)
    |> assign(:remote_node, remote_node)
    |> maybe_assign_node(node)
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
    |> noreply()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id={@id}
      phx-hook="DetailsPanelResize"
      aria-hidden={not @open}
      inert={not @open}
      class={[
        "details-panel",
        "border-base-200 bg-base-100 absolute inset-y-0 right-0 z-40 flex w-full flex-col border-l p-2 shadow-2xl transition-transform duration-300 ease-in-out",
        if(@open, do: "translate-x-0", else: "translate-x-full")
      ]}
    >
      <.resize_handle open={@open} />
      <%= if @node do %>
        <%!-- Header --%>
        <div class="border-base-200 flex items-start gap-3 border-b px-5 py-4">
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <.node_type_label node_type={@node.type} />
            <.node_label node={@node} />
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <.tooltip
              :if={is_pid(@node.pid)}
              id="details-panel-refresh-tip"
              position="bottom"
            >
              <button
                type="button"
                id="details-panel-refresh"
                phx-click="refresh-node-info"
                phx-target={@myself}
                phx-throttle="1000"
                aria-label="Refresh fetched process information"
                class="border-base-200 text-base-content/50 flex h-7 w-7 cursor-pointer items-center justify-center rounded-md border transition-all hover:border-base-300 hover:bg-base-200 hover:text-base-content"
              >
                <.icon
                  name="icon-rotate-cw"
                  class={["size-3.5", @node_info.loading && "motion-safe:animate-spin"]}
                />
              </button>
              <:content>Refresh fetched process information</:content>
            </.tooltip>
            <button
              type="button"
              id="details-panel-close"
              phx-click="close-details-panel"
              title="Close"
              aria-label="Close panel"
              class="border-base-200 text-base-content/50 flex h-7 w-7 cursor-pointer items-center justify-center rounded-md border transition-all hover:border-base-300 hover:bg-base-200 hover:text-base-content"
            >
              <.icon name="icon-x" class="size-3.5" />
            </button>
          </div>
        </div>
        <%!-- Scrollable body --%>
        <.body
          node_info={@node_info}
          node={@node}
          links_expanded?={@links_expanded?}
          myself={@myself}
        />
      <% end %>
    </aside>
    """
  end

  defp maybe_assign_node(socket, nil), do: assign(socket, :open, false)

  defp maybe_assign_node(socket, node) do
    socket = assign(socket, :open, true)

    if node_changed?(socket, node) do
      socket
      |> assign(:node, node)
      |> assign(:links_expanded?, false)
      |> maybe_fetch_node_info(node)
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

  defp maybe_fetch_node_info(socket, _node) do
    assign(socket, :node_info, AsyncResult.ok(%{}))
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
end
