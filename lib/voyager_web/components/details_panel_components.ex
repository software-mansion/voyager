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
  # Public so DetailsPanel can cap its remote fetch at what this panel renders.
  @max_expanded_links 200
  def max_expanded_links, do: @max_expanded_links

  attr :panel_id, :string, required: true
  attr :open?, :boolean, required: true

  def resize_handle(assigns) do
    ~H"""
    <div
      id={"#{@panel_id}-resize-handle"}
      data-resize-handle
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize details panel"
      class={[
        "group absolute inset-y-0 -left-1.5 z-50 hidden w-3 cursor-col-resize touch-none items-center justify-center",
        @open? && "lg:flex"
      ]}
    >
      <span class="absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 transition-colors group-hover:bg-primary/60" />
      <span class="bg-primary/60 relative z-50 flex h-10 w-1 shrink-0 flex-col items-center justify-center gap-0.5 rounded-full transition-colors group-hover:hidden">
        <span :for={_ <- 1..3} class="size-0.5 bg-base-100 rounded-full" />
      </span>
    </div>
    """
  end

  attr :node_type, :atom, required: true

  def node_type_label(assigns) do
    assigns =
      assigns
      |> assign(:label, assigns.node_type |> to_string() |> String.capitalize())
      |> assign(:icon, SupervisionTreeComponents.node_icons() |> Map.get(assigns.node_type))

    ~H"""
    <div class="flex items-center gap-2">
      <.icon :if={@icon} name={@icon.name} class={["size-3.5", @icon.color_class]} />
      <div class="font-mono text-base-content text-xs uppercase">{@label}</div>
    </div>
    """
  end

  attr :panel_id, :string, required: true
  attr :node, TreeNode, required: true

  def node_label(assigns) do
    assigns =
      assigns
      |> assign(:display_name, node_display_name(assigns.node))
      |> assign(:pid_string, node_pid_string(assigns.node))

    ~H"""
    <div class="flex min-w-0 flex-col gap-0.5">
      <.copyable
        id={"#{@panel_id}-name"}
        class="font-mono text-base-content break-all text-sm font-medium"
        text={@display_name}
        label="Copy Node name"
      />
      <.copyable
        :if={@pid_string}
        id={"#{@panel_id}-pid"}
        class="font-mono text-base-content/70 text-xs"
        text={@pid_string}
        label="Copy Node PID"
      />
    </div>
    """
  end

  attr :panel_id, :string, required: true
  attr :myself, :any, required: true
  attr :loading?, :boolean, required: true

  def refresh_button(assigns) do
    ~H"""
    <.tooltip id={"#{@panel_id}-refresh-tip"} position="bottom">
      <button
        type="button"
        id={"#{@panel_id}-refresh"}
        phx-click="refresh-node-info"
        phx-target={@myself}
        phx-throttle="1000"
        aria-label="Refresh fetched process information"
        title="Refresh fetched process information"
        class="btn btn-ghost btn-square toolbar-btn"
      >
        <.icon
          name="icon-rotate-cw"
          class={["toolbar-icon", @loading? && "motion-safe:animate-spin"]}
        />
      </button>
      <:content>Refresh fetched process information</:content>
    </.tooltip>
    """
  end

  attr :panel_id, :string, required: true

  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@panel_id}-close"}
      phx-click="close-details-panel"
      title="Close"
      aria-label="Close panel"
      class="btn btn-ghost btn-square toolbar-btn hover:text-base-content"
    >
      <%!-- size-6 because icon-x is visually smaller than the refresh icon --%>
      <.icon name="icon-x" class="size-6" />
    </button>
    """
  end

  attr :panel_id, :string, required: true

  attr :navigate, :string,
    default: nil,
    doc: "where Show More leads; disabled as Soon when absent"

  def show_more_button(assigns) do
    ~H"""
    <div class="border-base-200 flex justify-center border-t px-5 py-3">
      <.link
        :if={@navigate}
        id={"#{@panel_id}-show-more"}
        navigate={@navigate}
        class="btn btn-ghost gap-2 hover:text-primary"
      >
        Show More <.icon name="icon-arrow-right" class="size-4" />
      </.link>
      <button
        :if={!@navigate}
        type="button"
        id={"#{@panel_id}-show-more"}
        class="btn btn-ghost gap-2 hover:text-primary"
        disabled
      >
        Show More <span class="badge badge-primary badge-soft badge-xs">Soon</span>
      </button>
    </div>
    """
  end

  attr :panel_id, :string, required: true
  attr :info, AsyncResult, required: true
  attr :links_info, AsyncResult, required: true
  attr :node, TreeNode, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def body(assigns) do
    assigns = assign(assigns, :process?, is_pid(assigns.node.pid))

    ~H"""
    <div class="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4">
      <%= if @process? do %>
        <.overview info={@info} />
        <.links
          panel_id={@panel_id}
          links_info={@links_info}
          links_expanded?={@links_expanded?}
          myself={@myself}
        />
        <.memory_and_garbage_collection info={@info} />
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
          <.kv_skeleton label="Initial call" wide />
          <.kv_skeleton label="Current function" wide />
          <.kv_skeleton label="Current stacktrace" wide />
          <.kv_skeleton label="Registered name" />
          <.kv_skeleton label="Label" />
          <.kv_skeleton label="Parent" />
          <.kv_skeleton label="Status" narrow />
          <.kv_skeleton label="Message queue len" narrow />
          <.kv_skeleton label="Message queue data" narrow />
          <.kv_skeleton label="Group leader" />
          <.kv_skeleton label="Priority" narrow />
          <.kv_skeleton label="Trap exit" narrow />
          <.kv_skeleton label="Reductions" />
          <.kv_skeleton label="Last calls" wide />
          <.kv_skeleton label="Catch level" narrow />
          <.kv_skeleton label="Trace" narrow />
          <.kv_skeleton label="Suspending" />
          <.kv_skeleton label="Sequential trace token" />
          <.kv_skeleton label="Error handler" last />
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.kv label="Initial call" value={format_mfa(info.initial_call)} />
        <.kv label="Current function" value={format_mfa(info.current_function)} />
        <.kv label="Current stacktrace" value={format_stacktrace(info.current_stacktrace)} />
        <.kv label="Registered name" value={format_registered_name(info.registered_name)} />
        <.kv label="Label" value={format_optional(info.label)} />
        <.kv label="Parent" value={format_optional_identifier(info.parent)} />
        <.kv label="Status" value={to_string(info.status)} />
        <.kv
          label="Message queue len"
          value={Formatters.format_integer(info.message_queue_len)}
        />
        <.kv label="Message queue data" value={to_string(info.message_queue_data)} />
        <.kv label="Group leader" value={format_identifier(info.group_leader)} />
        <.kv label="Priority" value={to_string(info.priority)} />
        <.kv label="Trap exit" value={to_string(info.trap_exit)} />
        <.kv label="Reductions" value={Formatters.format_integer(info.reductions)} />
        <.kv label="Last calls" value={format_last_calls(info.last_calls)} />
        <.kv label="Catch level" value={Formatters.format_integer(info.catch_level)} />
        <.kv label="Trace" value={Formatters.format_integer(info.trace)} />
        <.suspending_list suspending={info.suspending} />
        <.kv
          label="Sequential trace token"
          value={format_sequential_trace_token(info.sequential_trace_token)}
        />
        <.kv label="Error handler" value={inspect(info.error_handler)} />
      </.async_result>
    </.section>
    """
  end

  attr :panel_id, :string, required: true
  attr :links_info, AsyncResult, required: true
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def links(assigns) do
    assigns = assign(assigns, :links_count, links_count(assigns.links_info))

    ~H"""
    <.section title="Links" muted={@links_count}>
      <.async_result :let={info} assign={@links_info}>
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
          toggle_id={"#{@panel_id}-toggle-links"}
          links={info.items}
          total={info.total}
          links_expanded?={@links_expanded?}
          myself={@myself}
        />
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
          <.kv_skeleton label="Memory" narrow />
          <.kv_skeleton label="Stack and heaps" narrow />
          <.kv_skeleton label="Heap size" narrow />
          <.kv_skeleton label="Stack size" narrow />
          <.kv_skeleton label="GC min heap size" narrow />
          <.kv_skeleton label="GC fullsweep after" narrow last />
        </:loading>
        <:failed>
          <.load_error />
        </:failed>
        <.kv label="Memory" value={Formatters.format_bytes(info.memory)} />
        <.kv label="Stack and heaps" value={Formatters.format_bytes(info.stack_and_heap_size)} />
        <.kv label="Heap size" value={Formatters.format_bytes(info.heap_size)} />
        <.kv label="Stack size" value={Formatters.format_bytes(info.stack_size)} />
        <.kv label="GC min heap size" value={Formatters.format_bytes(info.gc_min_heap_size)} />
        <.kv label="GC fullsweep after" value={format_count(info.gc_fullsweep_after)} />
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
        <span :if={@muted} class="font-mono text-base-content/70 ml-1 text-xs font-normal">
          {@muted}
        </span>
      </h4>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil, doc: "text value; truncated on overflow but kept in `title`"
  attr :last, :boolean, default: false
  attr :stacked, :boolean, default: false

  slot :inner_block, doc: "markup value, for rows a plain `value` cannot express"

  def kv(assigns) do
    ~H"""
    <div class={[
      "font-mono flex gap-4 py-2.5 text-xs",
      if(@stacked, do: "flex-col items-stretch", else: "items-baseline justify-between"),
      not @last && "border-base-content/10 border-b"
    ]}>
      <span class="text-base-content/70 shrink-0">{@label}</span>
      <div
        class={["text-base-content min-w-0", not @stacked && "truncate text-right"]}
        title={@value}
      >
        {@value}{render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true

  def chip(assigns) do
    ~H"""
    <button
      type="button"
      disabled
      class="border-base-content/70 bg-base-200 text-base-content font-mono inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs"
    >
      <span class="bg-primary h-1.5 w-1.5 rounded-full" />
      {@label}
    </button>
    """
  end

  @spec load_error(any()) :: Phoenix.LiveView.Rendered.t()
  def load_error(assigns) do
    ~H"""
    <div class="alert alert-error border px-3 py-2.5 text-xs">
      <.icon name="icon-circle-alert" class="text-error size-4 shrink-0" />
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
      not @last && "border-base-content/10 border-b"
    ]}>
      <span class="text-base-content/70 shrink-0">{@label}</span>
      <div class={[
        "skeleton shrink-1 h-2.5 rounded",
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
        <span class="text-base-content/70">Suspendee</span>
        <span class="text-base-content/70 text-right">Active</span>
        <span class="text-base-content/70 text-right">Outstanding</span>
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

  attr :toggle_id, :string, required: true
  attr :links, :list, required: true, doc: "links kept by the remote, already truncated"
  attr :total, :integer, required: true, doc: "real link count on the remote node"
  attr :links_expanded?, :boolean, required: true
  attr :myself, :any, required: true

  def links_list(assigns) do
    limit = if assigns.links_expanded?, do: @max_expanded_links, else: @max_links

    assigns =
      assigns
      |> assign(:visible_links, format_links(assigns.links, limit))
      |> assign(:toggle?, assigns.total > @max_links)
      |> assign(:overflow_count, max(assigns.total - limit, 0))

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        <.chip :for={link <- @visible_links} label={link} />
      </div>
      <p
        :if={@links_expanded? and @overflow_count > 0}
        class="font-mono text-base-content/70 self-center text-xs"
      >
        +{Formatters.format_integer(@overflow_count)} more
      </p>
      <button
        :if={@toggle?}
        type="button"
        id={@toggle_id}
        phx-click="toggle-links"
        phx-target={@myself}
        class="btn btn-ghost btn-xs text-base-content/70 w-max items-center self-center px-3 py-2 hover:text-base-content"
      >
        {if(@links_expanded?, do: "Show Less", else: "Show More")}
      </button>
    </div>
    """
  end

  @doc """
  A single line of text with a copy button that appears on hover.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true
  attr :class, :any, default: nil

  def copyable(assigns) do
    ~H"""
    <div class="group flex min-w-0 items-center gap-1">
      <p id={@id} class={["min-w-0 truncate", @class]}>
        {@text}
      </p>
      <div id={"#{@id}-copy-text"} class="hidden">{@text}</div>
      <.copy_button
        id={"#{@id}-copy"}
        target={"##{@id}-copy-text"}
        icon_only
        label={@label}
        class="text-base-content/60 opacity-0 transition-opacity hover:text-base-content focus-visible:opacity-100 group-hover:opacity-100"
      />
    </div>
    """
  end

  defp format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp format_mfa(mfa), do: inspect(mfa)

  defp format_registered_name(nil), do: "—"
  defp format_registered_name(name) when is_atom(name), do: inspect(name)

  defp format_stacktrace([]), do: "[]"

  defp format_stacktrace(stacktrace) when is_list(stacktrace),
    do: Enum.map_join(stacktrace, ", ", &format_stack_entry/1)

  defp format_stack_entry({mod, fun, arity, _location}), do: format_mfa({mod, fun, arity})
  defp format_stack_entry(entry), do: format_mfa(entry)

  defp format_optional(nil), do: "—"
  defp format_optional(value), do: inspect(value)

  defp format_optional_identifier(nil), do: "—"
  defp format_optional_identifier(identifier), do: format_identifier(identifier)

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

  defp node_display_name(%TreeNode{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp node_display_name(%TreeNode{name: name}) when is_binary(name), do: name
  defp node_display_name(%TreeNode{key: key}), do: key

  defp node_pid_string(%TreeNode{pid: pid}) when is_pid(pid), do: format_identifier(pid)
  defp node_pid_string(_), do: nil

  # Formats only the rendered slice: every chip lands in the LiveView diff.
  defp format_links(links, limit) do
    links
    |> Enum.take(limit)
    |> Enum.map(&format_identifier/1)
  end

  defp links_count(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)})"

  defp links_count(_), do: nil
end
