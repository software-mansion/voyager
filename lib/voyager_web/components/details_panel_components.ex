defmodule VoyagerWeb.Components.DetailsPanelComponents do
  @moduledoc """
  Presentational components and value formatters for the supervision-tree
  details panel.
  """

  use VoyagerWeb, :component

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Pid
  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.ProcessInfoHelp

  @overview_rows [
    {:initial_call, "Initial call", :wide},
    {:current_function, "Current function", :wide},
    {:current_stacktrace, "Current stacktrace", :wide},
    {:registered_name, "Registered name", nil},
    {:label, "Label", nil},
    {:parent, "Parent", nil},
    {:status, "Status", :narrow},
    {:message_queue_len, "Message queue len", :narrow},
    {:message_queue_data, "Message queue data", :narrow},
    {:group_leader, "Group leader", nil},
    {:priority, "Priority", :narrow},
    {:trap_exit, "Trap exit", :narrow},
    {:reductions, "Reductions", nil},
    {:last_calls, "Last calls", :wide},
    {:catch_level, "Catch level", :narrow},
    {:trace, "Trace", :narrow},
    {:suspending, "Suspending", nil},
    {:sequential_trace_token, "Sequential trace token", nil},
    {:error_handler, "Error handler", nil}
  ]

  @byte_rows [
    {:memory, "Memory"},
    {:stack_and_heap_size, "Stack and heaps"},
    {:heap_size, "Heap size"},
    {:stack_size, "Stack size"},
    {:gc_min_heap_size, "GC min heap size"}
  ]

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

  attr :panel_id, :string, required: true
  attr :node_type, :atom, required: true
  attr :off_tree?, :boolean, default: false

  def node_type_label(assigns) do
    icons = SupervisionTreeComponents.node_icons()

    assigns =
      assigns
      |> assign(:label, assigns.node_type |> to_string() |> String.capitalize())
      |> assign(:icon, Map.get(icons, assigns.node_type, icons.worker))

    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.icon :if={@icon} name={@icon.name} class={["size-3.5", @icon.color_class]} />
      <div id={"#{@panel_id}-type"} class="font-mono text-base-content text-xs uppercase">
        {@label}
      </div>
      <span
        :if={@off_tree?}
        class="alert alert-warning px-2 py-1 text-xs"
      >
        Not in tree
      </span>
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
        label="Copy node name"
      />
      <.copyable
        :if={@pid_string}
        id={"#{@panel_id}-pid"}
        class="font-mono text-base-content/70 text-xs"
        text={@pid_string}
        label="Copy node PID"
      />
    </div>
    """
  end

  attr :panel_id, :string, required: true
  attr :on_refresh, :string, required: true
  attr :target, :any, required: true
  attr :loading?, :boolean, required: true

  def refresh_button(assigns) do
    ~H"""
    <.tooltip id={"#{@panel_id}-refresh-tip"} position="bottom">
      <button
        type="button"
        id={"#{@panel_id}-refresh"}
        phx-click={@on_refresh}
        phx-target={@target}
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
  attr :on_back, :string, required: true
  attr :target, :any, required: true

  def back_button(assigns) do
    ~H"""
    <.tooltip id={"#{@panel_id}-back-tip"} position="bottom">
      <button
        type="button"
        id={"#{@panel_id}-back"}
        phx-click={@on_back}
        phx-target={@target}
        title="Back to previous process"
        aria-label="Back to previous process"
        class="btn btn-ghost btn-square toolbar-btn hover:text-base-content"
      >
        <.icon name="icon-arrow-left" class="toolbar-icon" />
      </button>
      <:content>Back to previous process</:content>
    </.tooltip>
    """
  end

  attr :panel_id, :string, required: true
  attr :on_close, :string, required: true

  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@panel_id}-close"}
      phx-click={@on_close}
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
  attr :href, :string, default: nil, doc: "process info page path; nil renders nothing"

  def show_more_button(assigns) do
    ~H"""
    <div :if={@href} class="border-base-200 flex justify-center border-t px-5 py-3">
      <.link
        id={"#{@panel_id}-show-more"}
        href={@href}
        class="btn btn-ghost gap-2 hover:text-primary"
      >
        Show more <.icon name="icon-arrow-right" class="size-4" />
      </.link>
    </div>
    """
  end

  attr :panel_id, :string, required: true
  attr :info, AsyncResult, required: true
  attr :links_info, AsyncResult, required: true
  attr :node, TreeNode, required: true
  attr :links_expanded?, :boolean, required: true
  attr :on_select, :string, required: true
  attr :on_toggle_links, :string, required: true
  attr :target, :any, required: true
  attr :remote_node, :atom, default: nil, doc: "forwarded to `overview/1`"
  attr :links_disabled?, :boolean, default: false

  def body(assigns) do
    assigns = assign(assigns, :process?, is_pid(assigns.node.pid))

    ~H"""
    <div class="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4">
      <%= if @process? do %>
        <.overview
          info={@info}
          remote_node={@remote_node}
          panel_id={@panel_id}
          on_select={@on_select}
          target={@target}
          links_disabled?={@links_disabled?}
        />
        <.links
          panel_id={@panel_id}
          links_info={@links_info}
          links_expanded?={@links_expanded?}
          on_select={@on_select}
          on_toggle_links={@on_toggle_links}
          target={@target}
          links_disabled?={@links_disabled?}
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

  attr :size, :atom,
    default: :xs,
    values: [:xs, :sm],
    doc: "value font size, forwarded to `kv/1`"

  attr :remote_node, :atom,
    default: nil,
    doc: "parent and group leader pids on this node render as links"

  attr :current_url, :string,
    default: nil,
    doc: "renders linkable pid rows as plain process links instead of tree jumps"

  attr :panel_id, :string, default: nil
  attr :on_select, :string, default: nil, doc: "tree-jump event for linkable pid rows"
  attr :target, :any, default: nil
  attr :links_disabled?, :boolean, default: false

  def overview(assigns) do
    assigns = assign(assigns, :rows, @overview_rows)

    ~H"""
    <.section title="Overview">
      <.async_result :let={info} assign={@info}>
        <:loading>
          <.kv_skeleton
            :for={{key, label, width} <- @rows}
            label={label}
            help={ProcessInfoHelp.get(key)}
            width={width}
            last={key == :error_handler}
          />
        </:loading>
        <:failed :let={failure}>
          <.load_error failure={failure} />
        </:failed>
        <%= for {key, label, _width} <- @rows do %>
          <.suspending_list :if={key == :suspending} suspending={info.suspending} size={@size} />
          <.kv :if={key != :suspending} size={@size} label={label} help={ProcessInfoHelp.get(key)}>
            <%= if pid = linkable_pid(key, info, @remote_node) do %>
              <ProcessComponents.process_link :if={@current_url} pid={pid} current_url={@current_url} />
              <.chip
                :if={is_nil(@current_url)}
                id={"#{@panel_id}-#{key}"}
                label={format_identifier(pid)}
                node_key={TreeNode.key(pid)}
                on_select={@on_select}
                target={@target}
                disabled={@links_disabled?}
              />
            <% else %>
              {overview_value(key, info)}
            <% end %>
          </.kv>
        <% end %>
      </.async_result>
    </.section>
    """
  end

  attr :panel_id, :string, required: true
  attr :links_info, AsyncResult, required: true
  attr :links_expanded?, :boolean, required: true
  attr :on_select, :string, required: true
  attr :on_toggle_links, :string, required: true
  attr :target, :any, required: true
  attr :links_disabled?, :boolean, default: false

  def links(assigns) do
    assigns = assign(assigns, :links_count, links_count(assigns.links_info))

    ~H"""
    <.section title="Links" muted={@links_count} help={SupervisionTreeComponents.edge_legend("Link")}>
      <.async_result :let={info} assign={@links_info}>
        <:loading>
          <div class="flex flex-wrap gap-1.5">
            <.chip_skeleton />
            <.chip_skeleton />
            <.chip_skeleton />
          </div>
        </:loading>
        <:failed :let={failure}>
          <.load_error failure={failure} />
        </:failed>
        <.links_list
          panel_id={@panel_id}
          toggle_id={"#{@panel_id}-toggle-links"}
          links={info.items}
          total={info.total}
          links_expanded?={@links_expanded?}
          on_select={@on_select}
          on_toggle_links={@on_toggle_links}
          target={@target}
          links_disabled?={@links_disabled?}
        />
      </.async_result>
    </.section>
    """
  end

  attr :info, AsyncResult, required: true

  attr :size, :atom,
    default: :xs,
    values: [:xs, :sm],
    doc: "value font size, forwarded to `kv/1`"

  def memory_and_garbage_collection(assigns) do
    assigns = assign(assigns, :byte_rows, @byte_rows)

    ~H"""
    <.section title="Memory and Garbage Collection">
      <.async_result :let={info} assign={@info}>
        <:loading>
          <.kv_skeleton
            :for={{key, label} <- @byte_rows}
            label={label}
            help={ProcessInfoHelp.get(key)}
            width={:narrow}
          />
          <.kv_skeleton
            label="GC fullsweep after"
            help={ProcessInfoHelp.get(:gc_fullsweep_after)}
            width={:narrow}
            last
          />
        </:loading>
        <:failed :let={failure}>
          <.load_error failure={failure} />
        </:failed>
        <.kv
          :for={{key, label} <- @byte_rows}
          size={@size}
          label={label}
          help={ProcessInfoHelp.get(key)}
        >
          <.bytes id={"process-#{key}"} value={Map.fetch!(info, key)} />
        </.kv>
        <.kv
          size={@size}
          label="GC fullsweep after"
          help={ProcessInfoHelp.get(:gc_fullsweep_after)}
          value={format_count(info.gc_fullsweep_after)}
        />
      </.async_result>
    </.section>
    """
  end

  attr :title, :string, required: true
  attr :muted, :string, default: nil
  attr :help, :map, default: nil, doc: "help entry rendered as a \"?\" tooltip next to the title"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    assigns =
      assign(assigns, :help_id, "section-help-" <> String.replace(assigns.title, " ", "-"))

    ~H"""
    <div class={@class}>
      <h4 class="text-base-content mb-2 flex items-center gap-1 text-sm font-semibold leading-none">
        {@title}
        <span :if={@muted} class="font-mono text-base-content/70 ml-1 text-xs font-normal">
          {@muted}
        </span>
        <.help_tooltip
          :if={@help}
          id={@help_id}
          entry={@help}
        />
      </h4>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil, doc: "text value; truncated on overflow but kept in `title`"
  attr :last, :boolean, default: false
  attr :stacked, :boolean, default: false
  attr :help, :map, default: nil, doc: "help entry rendered as a \"?\" tooltip next to the label"

  attr :size, :atom,
    default: :xs,
    values: [:xs, :sm],
    doc: "`:xs` for the sidebar panel; `:sm` matches full-page cards like node info"

  slot :inner_block, doc: "markup value, for rows a plain `value` cannot express"

  def kv(assigns) do
    ~H"""
    <div class={[
      "font-mono flex gap-4 py-2.5 text-xs",
      if(@stacked, do: "flex-col items-stretch", else: "items-baseline justify-between"),
      not @last && "border-base-content/10 border-b"
    ]}>
      <.kv_label label={@label} help={@help} />
      <div
        class={[
          "text-base-content min-w-0",
          @size == :sm && "text-sm",
          not @stacked && "truncate text-right"
        ]}
        title={@value}
      >
        {@value}
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :node_key, :string, required: true
  attr :on_select, :string, required: true
  attr :target, :any, required: true
  attr :disabled, :boolean, default: false

  def chip(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@on_select}
      phx-value-key={@node_key}
      phx-target={@target}
      disabled={@disabled}
      title={"Select #{@label}"}
      aria-label={"Select #{@label}"}
      class="border-base-content/70 bg-base-200 text-base-content inline-flex cursor-pointer rounded-md border px-2.5 py-1 text-xs transition-colors enabled:hover:border-primary enabled:hover:text-primary disabled:cursor-wait disabled:opacity-50"
    >
      <.display_pid pid={@label} />
    </button>
    """
  end

  attr :failure, :any, default: nil

  @spec load_error(any()) :: Phoenix.LiveView.Rendered.t()
  def load_error(assigns) do
    ~H"""
    <div class="alert alert-error border px-3 py-2.5 text-xs">
      <.icon name="icon-circle-alert" class="text-error size-4 shrink-0" />
      {load_error_message(@failure)}
    </div>
    """
  end

  defp load_error_message({:error, reason}), do: load_error_message(reason)
  defp load_error_message(:rate_limited), do: "Too many requests. Wait a moment and refresh."

  defp load_error_message(_failure), do: "Failed to load node details."

  attr :label, :string, required: true
  attr :help, :map, default: nil

  defp kv_label(assigns) do
    ~H"""
    <span class="text-base-content/70 flex shrink-0 items-center gap-1">
      {@label}
      <.help_tooltip
        :if={@help}
        id={"kv-help-" <> String.replace(@label, " ", "-")}
        entry={@help}
      />
    </span>
    """
  end

  attr :label, :string, required: true
  attr :help, :map, default: nil
  attr :width, :atom, default: nil, values: [nil, :narrow, :wide]
  attr :last, :boolean, default: false

  def kv_skeleton(assigns) do
    assigns = assign(assigns, :width_class, skeleton_width_class(assigns.width))

    ~H"""
    <div class={[
      "font-mono flex items-baseline justify-between gap-4 py-2.5 text-xs",
      not @last && "border-base-content/10 border-b"
    ]}>
      <.kv_label label={@label} help={@help} />
      <div class={["skeleton shrink-1 h-2.5 rounded", @width_class]} />
    </div>
    """
  end

  def chip_skeleton(assigns) do
    ~H"""
    <div class="skeleton h-6 w-16 rounded" />
    """
  end

  attr :suspending, :list, required: true

  attr :size, :atom,
    default: :xs,
    values: [:xs, :sm],
    doc: "value font size, forwarded to `kv/1`"

  def suspending_list(assigns) do
    assigns = assign(assigns, :suspending_count, length(assigns.suspending))

    ~H"""
    <.kv
      size={@size}
      label="Suspending"
      help={ProcessInfoHelp.get(:suspending)}
      stacked={@suspending_count > 0}
    >
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
  attr :panel_id, :string, required: true
  attr :links, :list, required: true, doc: "links kept by the remote, already truncated"
  attr :total, :integer, required: true, doc: "real link count on the remote node"
  attr :links_expanded?, :boolean, required: true
  attr :on_select, :string, required: true
  attr :on_toggle_links, :string, required: true
  attr :target, :any, required: true
  attr :links_disabled?, :boolean, default: false

  def links_list(assigns) do
    limit = if assigns.links_expanded?, do: @max_expanded_links, else: @max_links

    # Only the slice that gets rendered: a process can hold thousands of links
    # and every chip lands in the LiveView diff.
    assigns =
      assigns
      |> assign(:visible_links, Enum.take(assigns.links, limit))
      |> assign(:toggle?, assigns.total > @max_links)
      |> assign(:overflow_count, max(assigns.total - limit, 0))

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        <.chip
          :for={{link, index} <- Enum.with_index(@visible_links)}
          id={"#{@panel_id}-link-#{index}"}
          label={format_identifier(link)}
          node_key={TreeNode.key(link)}
          on_select={@on_select}
          target={@target}
          disabled={@links_disabled?}
        />
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
        phx-click={@on_toggle_links}
        phx-target={@target}
        class="btn btn-ghost btn-xs text-base-content/70 w-max items-center self-center px-3 py-2 hover:text-base-content"
      >
        {if(@links_expanded?, do: "Show less", else: "Show more")}
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

  @doc "The `:parent` or `:group_leader` pid when it lives on `remote_node`, else `nil`."
  @spec linkable_pid(atom(), map(), node() | nil) :: pid() | nil
  def linkable_pid(key, info, remote_node) when key in [:parent, :group_leader] do
    pid = Map.fetch!(info, key)
    if is_pid(pid) and node(pid) == remote_node, do: pid
  end

  def linkable_pid(_key, _info, _remote_node), do: nil

  defp overview_value(:initial_call, info), do: format_mfa(info.initial_call)
  defp overview_value(:current_function, info), do: format_mfa(info.current_function)
  defp overview_value(:current_stacktrace, info), do: format_stacktrace(info.current_stacktrace)
  defp overview_value(:registered_name, info), do: format_registered_name(info.registered_name)
  defp overview_value(:label, info), do: format_optional(info.label)
  defp overview_value(:parent, info), do: format_optional_identifier(info.parent)
  defp overview_value(:group_leader, info), do: format_identifier(info.group_leader)
  defp overview_value(:error_handler, info), do: inspect(info.error_handler)

  defp overview_value(:sequential_trace_token, info),
    do: format_sequential_trace_token(info.sequential_trace_token)

  defp overview_value(:last_calls, info), do: format_last_calls(info.last_calls)

  defp overview_value(key, info)
       when key in [:message_queue_len, :reductions, :catch_level, :trace],
       do: info |> Map.fetch!(key) |> Formatters.format_integer()

  defp overview_value(key, info), do: info |> Map.fetch!(key) |> to_string()

  defp skeleton_width_class(:narrow), do: "w-12"
  defp skeleton_width_class(:wide), do: "w-full"
  defp skeleton_width_class(nil), do: "w-20"

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
  defp format_optional(value), do: inspect(value, inspect_fun: &Pid.inspect_fun/2)

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

  defp format_identifier(pid) when is_pid(pid), do: Formatters.pid(pid)

  defp format_identifier(port) when is_port(port),
    do: port |> :erlang.port_to_list() |> List.to_string()

  defp format_identifier(other), do: inspect(other)

  defp node_display_name(%TreeNode{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp node_display_name(%TreeNode{name: name}) when is_binary(name), do: Formatters.pid(name)
  defp node_display_name(%TreeNode{key: key}), do: Formatters.pid(key)

  defp node_pid_string(%TreeNode{pid: pid}) when is_pid(pid), do: format_identifier(pid)
  defp node_pid_string(_), do: nil

  defp links_count(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)})"

  defp links_count(_), do: nil
end
