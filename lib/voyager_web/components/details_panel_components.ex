defmodule VoyagerWeb.Components.DetailsPanelComponents do
  @moduledoc """
  Presentational components and value formatters for the supervision-tree
  details panel.
  """

  use VoyagerWeb, :component

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.Formatters

  @max_links 12
  @max_expanded_links 200

  attr :open, :boolean, required: true

  def resize_handle(assigns) do
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
      <span class="absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 transition-colors group-hover:bg-primary/50" />
      <span class="bg-primary/50 relative z-50 flex h-10 w-1 shrink-0 flex-col items-center justify-center gap-0.5 rounded-full transition-colors group-hover:hidden">
        <span :for={_ <- 1..3} class="size-0.5 bg-base-100 rounded-full" />
      </span>
    </div>
    """
  end

  attr :node_type, :atom, required: true

  def node_type_label(assigns) do
    node_label = assigns.node_type |> to_string() |> String.capitalize()
    icon = node_icon(assigns.node_type)

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

  attr :node, TreeNode, required: true

  def node_label(assigns) do
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

  attr :node_info, AsyncResult, required: true
  attr :node, TreeNode, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def body(assigns) do
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

  def overview(assigns) do
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
            <.kv_skeleton label="Binary" />
            <.kv_skeleton label="Last calls" wide />
            <.kv_skeleton label="Catch level" narrow />
            <.kv_skeleton label="Trace" narrow />
            <.kv_skeleton label="Suspending" />
            <.kv_skeleton label="Sequential trace token" />
            <.kv_skeleton label="Error handler" last />
          </.info_box>
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.info_box>
          <.kv label="Initial call">
            {format_mfa(info.initial_call)}
          </.kv>
          <.kv label="Current function">
            {format_mfa(info.current_function)}
          </.kv>
          <.kv label="Registered name">
            {format_registered_name(info.registered_name)}
          </.kv>
          <.kv label="Status">
            {to_string(info.status)}
          </.kv>
          <.kv label="Message queue len">
            {Formatters.format_integer(info.message_queue_len)}
          </.kv>
          <.kv label="Group leader">
            {format_identifier(info.group_leader)}
          </.kv>
          <.kv label="Priority">
            {to_string(info.priority)}
          </.kv>
          <.kv label="Trap exit">
            {to_string(info.trap_exit)}
          </.kv>
          <.kv label="Reductions">
            {Formatters.format_integer(info.reductions)}
          </.kv>
          <.kv label="Binary">
            {format_binary(info.binary)}
          </.kv>
          <.kv label="Last calls">
            {format_last_calls(info.last_calls)}
          </.kv>
          <.kv label="Catch level">
            {Formatters.format_integer(info.catch_level)}
          </.kv>
          <.kv label="Trace">
            {Formatters.format_integer(info.trace)}
          </.kv>
          <.suspending_list suspending={info.suspending} />
          <.kv label="Sequential trace token">
            {format_sequential_trace_token(info.sequential_trace_token)}
          </.kv>
          <.kv label="Error handler">
            {inspect(info.error_handler)}
          </.kv>
        </.info_box>
      </.async_result>
    </.section>
    """
  end

  attr :info, AsyncResult, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def links(assigns) do
    assigns = assign(assigns, :links_count, links_count(assigns.info))

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
        <.links_list links={info.links} links_expanded?={@links_expanded?} myself={@myself} />
      </.async_result>
    </.section>
    """
  end

  attr :info, AsyncResult, required: true

  def memory_and_garbage_collection(assigns) do
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
          <.kv label="Memory">
            {Formatters.format_bytes(info.memory)}
          </.kv>
          <.kv label="Stack and heaps">
            {Formatters.format_bytes(info.stack_and_heap_size)}
          </.kv>
          <.kv label="Heap size">
            {Formatters.format_bytes(info.heap_size)}
          </.kv>
          <.kv label="Stack size">
            {Formatters.format_bytes(info.stack_size)}
          </.kv>
          <.kv label="GC min heap size">
            {Formatters.format_bytes(info.gc_min_heap_size)}
          </.kv>
          <.kv label="GC fullsweep after">
            {format_count(info.gc_fullsweep_after)}
          </.kv>
        </.info_box>
      </.async_result>
    </.section>
    """
  end

  attr :title, :string, required: true
  attr :muted, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
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

  def info_box(assigns) do
    ~H"""
    <div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :last, :boolean, default: false
  attr :stacked, :boolean, default: false

  slot :inner_block, required: true

  def kv(assigns) do
    ~H"""
    <div class={[
      "font-mono flex gap-4 py-2.5 text-xs",
      if(@stacked, do: "flex-col items-stretch", else: "items-baseline justify-between"),
      not @last && "border-base-300/60 border-b"
    ]}>
      <span class="text-base-content/60 shrink-0">{@label}</span>
      <div class={["text-base-content min-w-0", not @stacked && "truncate text-right"]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :pid, :string, required: true

  def chip(assigns) do
    # Redirecting will be available after #41 and #99
    ~H"""
    <button
      type="button"
      disabled
      title={@pid}
      class="border-base-content/60 bg-base-200 text-base-content font-mono inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs"
    >
      <span class="bg-primary h-1.5 w-1.5 rounded-full" />
      {@pid}
    </button>
    """
  end

  def load_error(assigns) do
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

  def kv_skeleton(assigns) do
    ~H"""
    <div class={[
      "font-mono flex items-baseline justify-between gap-4 py-2.5 text-xs",
      not @last && "border-base-300/60 border-b"
    ]}>
      <span class="text-base-content/60 shrink-0">{@label}</span>
      <div class={[
        "skeleton h-2.5 shrink-0 rounded",
        @narrow && "w-12",
        @wide && "w-full",
        (not @narrow and not @wide) && "w-20"
      ]} />
    </div>
    """
  end

  def chip_skeleton(assigns) do
    ~H"""
    <div class="skeleton h-6 w-16 rounded" />
    """
  end

  attr :suspending, :list, required: true

  def suspending_list(assigns) do
    assigns = assign(assigns, :suspending_count, length(assigns.suspending))

    ~H"""
    <.kv label="Suspending" stacked={@suspending_count > 0}>
      <span :if={@suspending == []}>[]</span>
      <div
        :if={@suspending != []}
        class="grid-cols-[minmax(0,1fr)_auto_auto] grid w-full gap-x-3 gap-y-1 text-left"
      >
        <span class="text-base-content/50">Suspendee</span>
        <span class="text-base-content/50 text-right">Active</span>
        <span class="text-base-content/50 text-right">Outstanding</span>
        <div
          :for={{suspendee, active_suspend_count, outstanding_suspend_count} <- @suspending}
          class="contents"
        >
          <span class="text-base-content truncate">{format_identifier(suspendee)}</span>
          <span class="text-base-content text-right">{active_suspend_count}</span>
          <span class="text-base-content text-right">{outstanding_suspend_count}</span>
        </div>
      </div>
    </.kv>
    """
  end

  attr :links, :list, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def links_list(assigns) do
    total = length(assigns.links)
    limit = if assigns.links_expanded?, do: @max_expanded_links, else: @max_links

    assigns =
      assigns
      |> assign(:visible_links, format_links(assigns.links, limit))
      |> assign(:toggle?, total > @max_links)
      |> assign(:overflow_count, max(total - limit, 0))

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        <.chip :for={pid <- @visible_links} pid={pid} />
      </div>
      <p
        :if={@links_expanded? and @overflow_count > 0}
        class="font-mono text-base-content/50 self-center text-xs"
      >
        +{Formatters.format_integer(@overflow_count)} more
      </p>
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

  defp format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp format_mfa(mfa), do: inspect(mfa)

  defp format_registered_name(nil), do: "—"
  defp format_registered_name(name) when is_atom(name), do: inspect(name)

  defp format_binary([]), do: "[]"

  defp format_binary(binaries) when is_list(binaries) do
    total_bytes =
      Enum.reduce(binaries, 0, fn
        {_id, size, _refs}, acc when is_integer(size) -> acc + size
        _, acc -> acc
      end)

    "#{length(binaries)} (#{Formatters.format_bytes(total_bytes)})"
  end

  defp format_last_calls(false), do: "false"
  defp format_last_calls([]), do: "[]"

  defp format_last_calls(calls) when is_list(calls),
    do: Enum.map_join(calls, ", ", &format_mfa/1)

  defp format_last_calls(calls), do: inspect(calls)

  defp format_sequential_trace_token(nil), do: "—"
  defp format_sequential_trace_token(token), do: inspect(token)

  defp format_count(nil), do: "—"
  defp format_count(n) when is_integer(n), do: Formatters.format_integer(n)

  defp format_identifier(pid) when is_pid(pid),
    do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp format_identifier(port) when is_port(port),
    do: port |> :erlang.port_to_list() |> List.to_string()

  defp format_identifier(other), do: inspect(other)

  defp node_icon(node_type) do
    SupervisionTreeComponents.node_legends()
    |> Enum.find(fn legend -> legend.type == node_type end)
    |> case do
      %{color_class: color_class, icon_name: icon_name} -> %{color: color_class, icon: icon_name}
      _ -> %{color: "text-base-content", icon: nil}
    end
  end

  defp node_display_name(%TreeNode{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp node_display_name(%TreeNode{name: name}) when is_binary(name), do: name
  defp node_display_name(%TreeNode{key: key}), do: key

  defp node_pid_string(%TreeNode{pid: pid}) when is_pid(pid), do: inspect(pid)
  defp node_pid_string(_), do: nil

  # Formats only the slice that gets rendered: a process can hold thousands of
  # links and every chip lands in the LiveView diff.
  defp format_links(links, limit) do
    links
    |> Enum.take(limit)
    |> Enum.map(&format_identifier/1)
  end

  defp links_count(%AsyncResult{ok?: true, result: %{links: links}}), do: "(#{length(links)})"
  defp links_count(_), do: nil
end
