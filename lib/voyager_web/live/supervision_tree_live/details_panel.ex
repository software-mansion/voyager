defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Side panel that displays details for a selected node in the supervision tree.

  The parent LiveView owns the current selection (graph highlight / focus) and
  passes the selected `TreeNode` (or `nil` to close) together with
  `keep_history?`. This component owns the in-panel navigation history: link
  clicks push the current node, Back pops it, and a selection without
  `keep_history?` (graph click, close) resets the stack.

  Link / back notify the parent via `send/2` (`{:select_link, id}` /
  `{:restore_details_node, node}`). Close has no `phx-target`, so it is handled
  on the parent as `"close-details-panel"`.
  """

  use VoyagerWeb, :live_component

  import VoyagerWeb.Components.DetailsPanelComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.RateLimiter
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Formatters

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
    |> assign(:selection_history, [])
    |> assign(:node_info, AsyncResult.loading())
    |> assign(:links, AsyncResult.loading())
    |> ok()
  end

  @impl true
  def update(
        %{
          id: id,
          tree_node: tree_node,
          remote_node: remote_node,
          node_name: node_name,
          current_url: current_url,
          keep_history?: keep_history?
        },
        socket
      ) do
    socket
    |> assign(:id, id)
    |> assign(:remote_node, remote_node)
    |> assign(:node_name, node_name)
    |> assign(:current_url, current_url)
    |> maybe_assign_node(tree_node, keep_history?)
    |> ok()
  end

  @impl true
  def handle_event("toggle-links", _params, socket) do
    socket
    |> assign(:links_expanded?, not socket.assigns.links_expanded?)
    |> noreply()
  end

  def handle_event("select-link", %{"key" => key}, socket) do
    case link_by_key(socket.assigns.links, key) || info_pid_by_key(socket, key) do
      nil ->
        noreply(socket)

      identifier ->
        send(self(), {:select_link, identifier})

        socket
        |> push_history()
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
            <.node_type_label panel_id={@id} node_type={@node.type} off_tree?={@node.placeholder?} />
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
          links_info={@links}
          node={@node}
          links_expanded?={@links_expanded?}
          on_select="select-link"
          on_toggle_links="toggle-links"
          target={@myself}
          remote_node={@remote_node}
        />
        <.show_more_button
          panel_id={@id}
          href={process_href(@node.pid, @remote_node, @node_name, @current_url)}
        />
      <% end %>
    </aside>
    """
  end

  # Only pids living on the inspected node have a process page.
  defp process_href(pid, remote_node, node_name, current_url)
       when is_pid(pid) and node(pid) == remote_node and is_binary(node_name) do
    keep_sidebar(~p"/node/#{node_name}/processes/#{Formatters.format_pid(pid)}", current_url)
  end

  defp process_href(_pid, _remote_node, _node_name, _current_url), do: nil

  defp maybe_assign_node(socket, nil, _keep_history?) do
    socket
    |> assign(:open?, false)
    |> assign(:selection_history, [])
  end

  defp maybe_assign_node(socket, node, keep_history?) do
    changed? = node_changed?(socket, node)

    socket
    |> assign(:open?, true)
    |> assign(:node, node)
    |> then(fn socket ->
      if keep_history?, do: socket, else: assign(socket, :selection_history, [])
    end)
    |> then(fn socket ->
      if changed?, do: assign(socket, :links_expanded?, false), else: socket
    end)
    |> maybe_fetch_node_info(node)
    |> maybe_fetch_links(node)
  end

  defp push_history(%{assigns: %{node: %TreeNode{} = node}} = socket),
    do: assign(socket, :selection_history, [node | socket.assigns.selection_history])

  defp push_history(socket), do: socket

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
    result =
      rate_limited(fn ->
        with {:ok, info} <- ProcessInfo.fetch(remote_node, pid) do
          {:ok, Map.put(info, :label, fetch_label(remote_node, pid))}
        end
      end)

    case result do
      {:ok, info} ->
        {:ok, %{node_info: info}}

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
    case rate_limited(fn -> ProcessInfo.fetch_links(remote_node, pid, @links_limit) end) do
      {:ok, bounded} ->
        {:ok, %{links: bounded}}

      {:error, reason} ->
        Logger.warning(
          "Failed to load links for #{inspect(remote_node)}/#{inspect(pid)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp rate_limited(fun) do
    case RateLimiter.run(:high, fun) do
      {:ok, result, _elapsed_us} -> result
      {:error, :rate_limited, _retry_after_ms} -> {:error, :rate_limited}
    end
  end

  defp link_by_key(%AsyncResult{ok?: true, result: %{items: links}}, key) when is_list(links) do
    Enum.find(links, &(TreeNode.key(&1) == key))
  end

  defp link_by_key(_, _), do: nil

  defp info_pid_by_key(
         %{assigns: %{node_info: %AsyncResult{ok?: true, result: info}}} = socket,
         key
       )
       when is_map(info) do
    Enum.find([info.parent, info.group_leader], fn pid ->
      is_pid(pid) and node(pid) == socket.assigns.remote_node and TreeNode.key(pid) == key
    end)
  end

  defp info_pid_by_key(_socket, _key), do: nil
end
