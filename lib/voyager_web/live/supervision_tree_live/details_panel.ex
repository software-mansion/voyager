defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanel do
  @moduledoc """
  Side panel that displays details for a selected node in the supervision tree.
  """

  use VoyagerWeb, :live_component

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Components.SupervisionTreeComponents

  require Logger

  @max_links 12

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

  # Keep the last node while sliding out so the panel doesn't blank mid-animation
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

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="details-panel"
      phx-hook="DetailsPanelResize"
      class={[
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

  attr :open, :boolean, required: true

  defp resize_handle(assigns) do
    ~H"""
    <div
      id="details-panel-resize-handle"
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize details panel"
      class={[
        "group absolute inset-y-0 -left-1.5 z-50 hidden w-3 cursor-col-resize touch-none items-center justify-center",
        @open && "lg:flex"
      ]}
    >
      <span class="w-0.75 absolute inset-y-0 left-1/2 -translate-x-1/2 transition-colors group-hover:bg-primary/50" />
      <span class="bg-primary/50 relative z-50 flex h-10 w-1 shrink-0 flex-col items-center justify-center gap-0.5 rounded-full transition-colors group-hover:hidden">
        <span :for={_ <- 1..3} class="size-0.5 bg-base-100 rounded-full" />
      </span>
    </div>
    """
  end

  attr :node_type, :atom, required: true

  defp node_type_label(assigns) do
    node_label = assigns.node_type |> to_string() |> String.capitalize()
    icon = node_icon(node_label)

    assigns =
      assigns
      |> assign(:label, node_label)
      |> assign(:icon, icon)

    ~H"""
    <div class="flex items-center gap-2">
      <.icon :if={@icon.icon} name={@icon.icon} class={["size-3.5", @icon.color]} />
      <div class="font-mono text-base-content text-xs uppercase">{@label}</div>
    </div>
    """
  end

  defp node_icon(node_label) do
    SupervisionTreeComponents.node_legends()
    |> Enum.find(fn legend -> legend.name == node_label end)
    |> case do
      %{color_class: color_class, icon_name: icon_name} -> %{color: color_class, icon: icon_name}
      _ -> %{color: "text-base-content", icon: nil}
    end
  end

  attr :node, TreeNode, required: true

  defp node_label(assigns) do
    assigns =
      assigns
      |> assign(:display_name, node_display_name(assigns.node))
      |> assign(:pid_string, node_pid_string(assigns.node))

    ~H"""
    <div>
      <p class="font-mono text-base-content truncate break-all text-sm font-medium">
        {@display_name}
      </p>
      <p :if={@pid_string} class="font-mono text-base-content/50 mt-0.5 text-xs">
        {@pid_string}
      </p>
    </div>
    """
  end

  defp node_display_name(%TreeNode{name: name}) when is_atom(name), do: Atom.to_string(name)

  defp node_display_name(%TreeNode{name: name}) when is_binary(name), do: name
  defp node_display_name(%TreeNode{key: key}), do: key

  defp node_pid_string(%TreeNode{pid: pid}) when is_pid(pid), do: inspect(pid)
  defp node_pid_string(_), do: nil

  attr :node_info, AsyncResult, required: true
  attr :node, TreeNode, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  defp body(assigns) do
    assigns = assign(assigns, :process?, is_pid(assigns.node.pid))

    ~H"""
    <div class="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4">
      <%= if @process? do %>
        <.overview info={@node_info} />
        <.links info={@node_info} links_expanded?={@links_expanded?} myself={@myself} />
        <.memory_and_garbage_collection info={@node_info} />
      <% else %>
        <div class="alert alert-info">
          <p>
            This is not a process node, so no process information is available.
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  attr :info, AsyncResult, required: true

  defp overview(assigns) do
    ~H"""
    <.section title="Overview">
      <.async_result :let={info} assign={@info}>
        <:loading>
          <.info_box>
            <.kv_skeleton label="Initial call" wide />
            <.kv_skeleton label="Current function" wide />
            <.kv_skeleton label="Registered name" />
            <.kv_skeleton label="Status" narrow />
            <.kv_skeleton label="Message queue len" narrow />
            <.kv_skeleton label="Group leader" />
            <.kv_skeleton label="Priority" narrow />
            <.kv_skeleton label="Trap exit" narrow />
            <.kv_skeleton label="Reductions" />
            <.kv_skeleton label="Catch level" narrow last />
          </.info_box>
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.info_box>
          <.kv label="Initial call" value={info.initial_call} />
          <.kv label="Current function" value={info.current_function} />
          <.kv label="Registered name" value={info.registered_name} />
          <.kv label="Status" value={info.status} />
          <.kv label="Message queue len" value={info.message_queue_len} />
          <.kv label="Group leader" value={info.group_leader} />
          <.kv label="Priority" value={info.priority} />
          <.kv label="Trap exit" value={info.trap_exit} />
          <.kv label="Reductions" value={info.reductions} />
          <.kv label="Catch level" value={info.catch_level} last />
        </.info_box>
      </.async_result>
    </.section>
    """
  end

  attr :info, AsyncResult, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  defp links(assigns) do
    assigns =
      assigns
      |> assign(:links_count, links_count(assigns.info))
      |> assign(:max_links, @max_links)

    ~H"""
    <.section title="Links" muted={@links_count}>
      <.async_result :let={info} assign={@info}>
        <:loading>
          <div class="flex flex-wrap gap-1.5">
            <.chip_skeleton />
            <.chip_skeleton />
            <.chip_skeleton />
          </div>
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.links_list
          links={info.links}
          links_expanded?={@links_expanded?}
          max_links={@max_links}
          myself={@myself}
        />
      </.async_result>
    </.section>
    """
  end

  attr :links, :list, required: true
  attr :links_expanded?, :boolean, required: true
  attr :max_links, :integer, required: true
  attr :myself, :any, required: true

  defp links_list(assigns) do
    assigns =
      assigns
      |> assign(
        :visible_links,
        visible_links(assigns.links, assigns.links_expanded?, assigns.max_links)
      )
      |> assign(:toggle?, length(assigns.links) > assigns.max_links)

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        <.chip :for={pid <- @visible_links} pid={pid} />
      </div>
      <button
        :if={@toggle?}
        type="button"
        id="details-panel-toggle-links"
        phx-click="toggle-links"
        phx-target={@myself}
        class="btn btn-ghost btn-xs text-base-content/60 w-max items-center self-center px-3 py-2 hover:text-base-content"
      >
        {if(@links_expanded?, do: "Show Less", else: "Show More")}
      </button>
    </div>
    """
  end

  defp visible_links(links, true, _max_links), do: links
  defp visible_links(links, false, max_links), do: Enum.take(links, max_links)

  defp links_count(%AsyncResult{ok?: true, result: %{links: links}}), do: "(#{length(links)})"
  defp links_count(_), do: nil

  attr :info, AsyncResult, required: true

  defp memory_and_garbage_collection(assigns) do
    ~H"""
    <.section title="Memory and Garbage Collection">
      <.async_result :let={info} assign={@info}>
        <:loading>
          <.info_box>
            <.kv_skeleton label="Memory" narrow />
            <.kv_skeleton label="Stack and heaps" narrow />
            <.kv_skeleton label="Heap size" narrow />
            <.kv_skeleton label="Stack size" narrow />
            <.kv_skeleton label="GC min heap size" narrow />
            <.kv_skeleton label="GC fullsweep after" narrow last />
          </.info_box>
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.info_box>
          <.kv label="Memory" value={info.memory} />
          <.kv label="Stack and heaps" value={info.stack_and_heaps} />
          <.kv label="Heap size" value={info.heap_size} />
          <.kv label="Stack size" value={info.stack_size} />
          <.kv label="GC min heap size" value={info.gc_min_heap_size} />
          <.kv label="GC fullsweep after" value={info.gc_fullsweep_after} last />
        </.info_box>
      </.async_result>
    </.section>
    """
  end

  attr :title, :string, required: true
  attr :muted, :string, default: nil
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div>
      <h4 class="text-base-content mb-2 text-sm font-semibold leading-none">
        {@title}
        <span :if={@muted} class="font-mono text-base-content/50 ml-1 text-xs font-normal">
          {@muted}
        </span>
      </h4>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  defp info_box(assigns) do
    ~H"""
    <div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :last, :boolean, default: false

  defp kv(assigns) do
    ~H"""
    <div class={[
      "font-mono grid grid-cols-2 items-baseline gap-4 py-2.5 text-xs",
      not @last && "border-base-300/60 border-b"
    ]}>
      <span class="text-base-content/60 truncate">{@label}</span>
      <span class="text-base-content truncate text-right" title={@value}>{@value}</span>
    </div>
    """
  end

  attr :pid, :string, required: true

  defp chip(assigns) do
    # Redirecting will be available after #41 and #99
    ~H"""
    <button
      type="button"
      disabled
      title={@pid}
      class="border-base-400 bg-base-200 text-base-content font-mono inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs"
    >
      <span class="bg-primary h-1.5 w-1.5 rounded-full" />
      {@pid}
    </button>
    """
  end

  defp load_error(assigns) do
    ~H"""
    <div class="border-error/30 bg-error/10 text-error rounded-lg border px-3 py-2.5 text-xs">
      Failed to load node details.
    </div>
    """
  end

  attr :label, :string, required: true
  attr :narrow, :boolean, default: false
  attr :wide, :boolean, default: false
  attr :last, :boolean, default: false

  defp kv_skeleton(assigns) do
    ~H"""
    <div class={[
      "font-mono grid grid-cols-2 items-baseline gap-4 py-2.5 text-xs",
      not @last && "border-base-300/60 border-b"
    ]}>
      <span class="text-base-content/60 truncate">{@label}</span>
      <div class={[
        "skeleton h-2.5 shrink-0 justify-self-end rounded",
        @narrow && "w-12",
        @wide && "w-full",
        (not @narrow and not @wide) && "w-20"
      ]} />
    </div>
    """
  end

  defp chip_skeleton(assigns) do
    ~H"""
    <div class="skeleton h-6 w-16 rounded" />
    """
  end
end
