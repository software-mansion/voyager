defmodule VoyagerWeb.Components.TracingBrowserComponents do
  @moduledoc """
  Components for the tracing sessions browser (`/node/:node/tracing`): the left
  session list card (header, node filter, pinned active tile, streamed history
  tiles, empty state and storage footer) and the right overview pane.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias Voyager.Services.Tracer.Summary
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.TermFormatter

  attr :count, :integer, required: true
  attr :save?, :boolean, required: true
  attr :busy?, :boolean, required: true
  attr :pending?, :boolean, required: true
  attr :on_toggle_save, :string, required: true
  attr :on_create, :string, required: true

  def list_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2">
      <div class="flex items-baseline gap-2">
        <h1 class="text-base-content text-base font-semibold">Sessions</h1>
        <span id="session-count" class="font-mono text-base-content/60 text-sm tabular-nums">
          {Formatters.format_integer(@count)}
        </span>
      </div>
      <div class="flex items-center gap-2">
        <label class="text-base-content/70 flex cursor-pointer select-none items-center gap-1.5 text-xs">
          <input
            type="checkbox"
            id="save-new-session"
            checked={@save?}
            phx-click={@on_toggle_save}
            class="toggle toggle-xs toggle-primary"
          />
          <span>Save</span>
        </label>
        <.tooltip :if={@busy?} id="create-session-tip" position="bottom">
          <button
            type="button"
            id="create-session"
            aria-disabled="true"
            class="btn btn-primary btn-sm"
          >
            <.icon name="icon-plus" class="size-3.5" /> New session
          </button>
          <:content>Stop the running session first</:content>
        </.tooltip>
        <button
          :if={!@busy?}
          type="button"
          id="create-session"
          phx-click={@on_create}
          disabled={@pending?}
          class="btn btn-primary btn-sm"
        >
          <.icon name="icon-plus" class="size-3.5" /> New session
        </button>
      </div>
    </div>
    """
  end

  attr :node_filter, :string, required: true
  attr :connected_node, :string, required: true
  attr :node_counts, :map, required: true
  attr :total_history, :integer, required: true
  attr :on_filter, :string, required: true

  def node_filter_bar(assigns) do
    assigns = assign(assigns, :nodes, sorted_nodes(assigns.node_counts, assigns.connected_node))

    ~H"""
    <div id="node-filter" class="min-h-7 flex items-center">
      <%= if @node_filter == "all" do %>
        <details
          id="node-picker"
          phx-mounted={JS.ignore_attributes("open")}
          phx-click-away={JS.remove_attribute("open")}
          class="dropdown"
        >
          <summary
            id="node-picker-trigger"
            phx-keydown={JS.remove_attribute("open", to: "#node-picker")}
            phx-key="Escape"
            class="btn btn-sm btn-ghost border-base-300 list-none gap-1.5 border font-normal"
          >
            <.icon name="icon-network" class="size-3.5 -rotate-90 opacity-60" />
            <span>All nodes</span>
            <.icon name="icon-chevron-right" class="size-3 rotate-90 opacity-60" />
          </summary>
          <ul
            phx-click={JS.remove_attribute("open", to: "#node-picker")}
            class="dropdown-content menu bg-base-100 rounded-box border-base-200 z-20 mt-1 w-72 border p-1.5 shadow-lg"
          >
            <li class="menu-title font-mono tracking-label px-2 text-xs uppercase">Filter by node</li>
            <li>
              <button
                type="button"
                id="node-filter-all"
                phx-click={@on_filter}
                phx-value-node="all"
                class={["flex items-center gap-2", @node_filter == "all" && "menu-active"]}
              >
                <span class="flex-1 text-left text-xs">All nodes</span>
                <span class="font-mono text-base-content/60 text-xs tabular-nums">
                  {Formatters.format_integer(@total_history)}
                </span>
              </button>
            </li>
            <li :for={{node, count} <- @nodes}>
              <button
                type="button"
                phx-click={@on_filter}
                phx-value-node={node}
                data-filter-node={node}
                class={["flex items-center gap-2", node == @node_filter && "menu-active"]}
              >
                <span class="font-mono min-w-0 flex-1 truncate text-left text-xs">{node}</span>
                <span
                  :if={node == @connected_node}
                  class="badge badge-xs badge-soft badge-success shrink-0"
                >
                  connected
                </span>
                <span class="font-mono text-base-content/60 shrink-0 text-xs tabular-nums">
                  {Formatters.format_integer(count)}
                </span>
              </button>
            </li>
          </ul>
        </details>
      <% else %>
        <span
          id="node-filter-chip"
          class="border-base-300 bg-base-200 flex min-w-0 max-w-full items-center gap-1.5 rounded-lg border py-0.5 pr-0.5 pl-2"
        >
          <span class="font-mono tracking-label text-base-content/50 shrink-0 text-xs font-semibold uppercase">
            Node
          </span>
          <span class="font-mono text-base-content/90 min-w-0 truncate text-xs">{@node_filter}</span>
          <button
            type="button"
            id="node-filter-clear"
            phx-click={@on_filter}
            phx-value-node="all"
            aria-label="Show sessions from all nodes"
            title="Show all nodes"
            class="btn btn-ghost btn-xs btn-square text-base-content/60 hover:text-base-content"
          >
            <.icon name="icon-x" class="size-3" />
          </button>
        </span>
        <button
          :if={@node_filter != @connected_node}
          type="button"
          id="node-filter-connected"
          phx-click={@on_filter}
          phx-value-node={@connected_node}
          class="btn btn-ghost btn-xs text-base-content/70 ml-2"
        >
          This node
        </button>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :active?, :boolean, default: false
  attr :selected?, :boolean, required: true
  attr :connected_node, :string, required: true
  attr :now, DateTime, required: true
  attr :on_select, :string, required: true

  def session_tile(assigns) do
    tone = item_tone(assigns.item)
    other_node? = item_other_node?(assigns.item, assigns.connected_node)
    {module, function} = item_mfa_parts(assigns.item.config)

    assigns =
      assign(assigns,
        tone: tone,
        other_node?: other_node?,
        module: module,
        function: function,
        frame_class: tile_frame_class(assigns.active?, other_node?, tone, assigns.selected?)
      )

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@on_select}
      phx-value-id={@item.id}
      data-tone={@tone}
      data-selected={@selected?}
      class={[
        "flex w-full flex-col gap-1 rounded-lg px-3.5 py-2.5 text-left transition-colors",
        @frame_class,
        @selected? && "bg-primary/10 ring-primary/40 ring-1"
      ]}
    >
      <span class="flex min-w-0 items-center gap-2">
        <span class="size-2 relative flex shrink-0">
          <span
            :if={@item.status == :running}
            class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-75"
          ></span>
          <span class={[
            "size-2 relative inline-flex rounded-full",
            TracingComponents.tone_class(@tone, :dot)
          ]}></span>
        </span>
        <span class={["min-w-0 flex-1 truncate text-sm font-semibold", @item.config && "font-mono"]}>
          <span :if={@module != ""} class="text-base-content/50 font-medium">{@module}</span>{@function}
        </span>
        <.icon
          name={origin_icon(@item.origin)}
          title={"Started from #{origin_label(@item.origin)}"}
          class="text-base-content/40 size-4 shrink-0"
        />
      </span>
      <span class="flex min-w-0 items-center gap-2 pl-4 text-sm">
        <span class={["shrink-0 truncate", TracingComponents.tone_class(@tone, :label)]}>
          {tile_state_label(@item)}
        </span>
        <span
          :if={@active?}
          class={[
            "badge badge-xs shrink-0",
            if(@item.save,
              do: "badge-outline border-base-300 text-base-content/70",
              else: "badge-soft badge-warning"
            )
          ]}
        >
          {if @item.save, do: "Active", else: "Not saved"}
        </span>
        <span :if={@other_node?} class="font-mono text-info ml-auto min-w-0 truncate text-xs">
          {item_node(@item)}
        </span>
      </span>
      <span class="font-mono text-base-content/60 flex justify-between gap-2 pl-4 text-xs tabular-nums">
        <span class="truncate">{tile_meta(@item)}</span>
        <span class="shrink-0">{tile_ago(@item, @now)}</span>
      </span>
    </button>
    """
  end

  attr :hidden_count, :integer, required: true
  attr :node_filter, :string, required: true
  attr :connected_node, :string, required: true
  attr :on_filter, :string, required: true

  def empty_tiles(assigns) do
    ~H"""
    <div id="tiles-empty" class="flex flex-col items-center gap-2 px-4 py-8 text-center">
      <.icon name="icon-binoculars" class="text-base-content/40 size-6" />
      <p class="text-base-content text-sm font-medium">
        {empty_title(@node_filter, @connected_node)}
      </p>
      <p :if={@hidden_count > 0} class="text-base-content/60 text-xs">
        {Formatters.format_integer(@hidden_count)} saved on other nodes
      </p>
      <button
        :if={@hidden_count > 0}
        type="button"
        id="tiles-show-all-nodes"
        phx-click={@on_filter}
        phx-value-node="all"
        class="btn btn-sm btn-ghost border-base-300 mt-1 border"
      >
        Show all nodes
      </button>
    </div>
    """
  end

  attr :used_bytes, :integer, required: true
  attr :limit_mb, :integer, required: true

  def storage_footer(assigns) do
    limit_bytes = assigns.limit_mb * 1_000_000

    assigns =
      assign(assigns,
        limit_bytes: limit_bytes,
        percent: storage_percent(assigns.used_bytes, limit_bytes)
      )

    ~H"""
    <div id="storage-footer" class="border-base-200 flex flex-col gap-2 border-t px-5 py-4">
      <div class="flex items-baseline justify-between text-xs">
        <span class="font-mono tracking-label text-base-content/60 font-semibold uppercase">
          Storage · all nodes
        </span>
        <span class="font-mono text-base-content tabular-nums">
          {TracingComponents.format_storage_bytes(@used_bytes)}
          <span class="text-base-content/60">
            of {TracingComponents.format_storage_bytes(@limit_bytes)}
          </span>
        </span>
      </div>
      <div class="bg-base-content/10 flex h-1.5 overflow-hidden rounded-full">
        <span class="bg-primary block h-full transition-all" style={"width: #{@percent}%"}></span>
      </div>
    </div>
    """
  end

  def no_selection_state(assigns) do
    ~H"""
    <div
      id="overview-empty"
      class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col items-center justify-center gap-3 border p-10 shadow-sm"
    >
      <.icon name="icon-binoculars" class="text-base-content/60 size-8" />
      <div class="text-center">
        <p class="text-base-content font-semibold">No session selected</p>
        <p class="text-base-content/70 mt-0.5 text-sm">
          Create a session, or pick one from another node.
        </p>
      </div>
    </div>
    """
  end

  def idle_overview_state(assigns) do
    ~H"""
    <div
      id="overview-idle"
      class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col items-center justify-center gap-3 border p-10 shadow-sm"
    >
      <.icon name="icon-binoculars" class="text-base-content/60 size-8" />
      <div class="text-center">
        <p class="text-base-content font-semibold">Nothing to show yet</p>
        <p class="text-base-content/70 mt-0.5 text-sm">
          Open the session to set its parameters and start it.
        </p>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :active?, :boolean, required: true
  attr :busy?, :boolean, required: true
  attr :pending?, :boolean, required: true
  attr :connected_node, :string, required: true
  attr :runtime_seconds, :integer, default: 0
  attr :storage_limit_mb, :integer, required: true
  attr :open_href, :string, required: true
  attr :on_stop, :string, required: true
  attr :on_unload, :string, required: true
  attr :on_load, :string, required: true
  attr :on_copy, :string, required: true
  attr :on_delete, :string, required: true

  def overview_session_card(assigns) do
    tone = item_tone(assigns.item)
    other_node? = item_other_node?(assigns.item, assigns.connected_node)
    {module, function} = item_mfa_parts(assigns.item.config)

    assigns =
      assign(assigns,
        tone: tone,
        other_node?: other_node?,
        node_label: item_node(assigns.item),
        module: module,
        function: function,
        saved?: item_saved?(assigns.item),
        ran?: assigns.item.status != :idle,
        chips:
          if(assigns.item.config,
            do: TracingComponents.config_chips(assigns.item.config),
            else: []
          )
      )

    ~H"""
    <div
      id="session-card"
      data-session-id={@item.id}
      class="card bg-base-100 border-base-200 text-base-content flex-none border shadow-sm"
    >
      <div class="flex items-start gap-4 px-5 py-4">
        <div class="min-w-0 flex-1">
          <div class="flex min-w-0 items-center gap-2 text-xs">
            <span
              id="overview-status"
              data-tone={@tone}
              class={[
                "badge badge-sm shrink-0 gap-1.5 font-semibold",
                TracingComponents.tone_class(@tone, :status_badge)
              ]}
            >
              <span class="size-1.5 relative flex">
                <span
                  :if={@item.status == :running}
                  class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-75"
                ></span>
                <span class={[
                  "size-1.5 relative inline-flex rounded-full",
                  TracingComponents.tone_class(@tone, :dot)
                ]}></span>
              </span>
              {overview_state_label(@item)}
            </span>
            <span
              :if={@saved?}
              id="overview-saved"
              class="badge badge-sm badge-outline border-base-300 text-base-content/70 shrink-0 font-medium"
            >
              Saved
            </span>
            <span id="overview-meta" class="text-base-content/60 truncate">
              {overview_meta_lead(@item, @active?)}
              <span :if={@other_node?}>
                · on <span class="font-mono text-info">{@node_label}</span>
              </span>
              <span :if={!@active?}> · {origin_label(@item.origin)}</span>
            </span>
          </div>

          <.tooltip
            id={"overview-params-#{@item.id}"}
            position="bottom"
            class="mt-2 flex w-fit min-w-0 max-w-full flex-col items-start gap-2.5"
          >
            <h2
              id="overview-mfa"
              tabindex="0"
              class={[
                "text-base-content max-w-full truncate text-lg font-semibold",
                @item.config && "font-mono"
              ]}
            >
              <span :if={@module != ""} class="text-base-content/50 font-medium">{@module}</span>{@function}
            </h2>
            <div :if={@chips != []} class="flex flex-wrap gap-1.5">
              <span
                :for={{key, label, value} <- @chips}
                id={"overview-chip-#{key}"}
                class="border-base-300 bg-base-200 flex min-w-0 max-w-full items-center gap-1.5 rounded-lg border px-2 py-1"
              >
                <span class="font-mono tracking-label text-base-content/50 shrink-0 text-xs font-semibold uppercase">
                  {label}
                </span>
                <span class="font-mono text-base-content/90 truncate text-xs">{value}</span>
              </span>
            </div>
            <:content>
              <TracingComponents.config_table :if={@item.config} config={@item.config} />
              <span :if={!@item.config}>No parameters yet</span>
            </:content>
          </.tooltip>
        </div>

        <.overview_actions
          item={@item}
          active?={@active?}
          other_node?={@other_node?}
          busy?={@busy?}
          pending?={@pending?}
          connected_node={@connected_node}
          open_href={@open_href}
          on_stop={@on_stop}
          on_unload={@on_unload}
          on_load={@on_load}
          on_copy={@on_copy}
          on_delete={@on_delete}
        />
      </div>

      <div
        :if={@active? and @other_node?}
        id="other-node-note"
        role="note"
        class="bg-info/10 border-info/30 text-base-content/80 mx-5 mb-4 flex items-center gap-2 rounded-lg border px-3 py-2 text-sm"
      >
        <.icon name="icon-info" class="text-info size-4 shrink-0" />
        <span>
          This session traced <span class="font-mono">{@node_label}</span>. Unload it to start tracing {@connected_node}.
        </span>
      </div>

      <.overview_totals
        :if={@ran?}
        item={@item}
        saved?={@saved?}
        runtime_seconds={@runtime_seconds}
        storage_limit_mb={@storage_limit_mb}
      />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :active?, :boolean, required: true
  attr :other_node?, :boolean, required: true
  attr :busy?, :boolean, required: true
  attr :pending?, :boolean, required: true
  attr :connected_node, :string, required: true
  attr :open_href, :string, required: true
  attr :on_stop, :string, required: true
  attr :on_unload, :string, required: true
  attr :on_load, :string, required: true
  attr :on_copy, :string, required: true
  attr :on_delete, :string, required: true

  defp overview_actions(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-2">
      <button
        :if={@active? and @item.status == :running}
        type="button"
        id="stop-session"
        phx-click={@on_stop}
        disabled={@pending?}
        class="btn btn-sm btn-soft btn-error"
      >
        <.icon name="icon-square-filled" class="size-3.5" /> Stop
      </button>

      <button
        :if={@active? and @item.status != :running}
        type="button"
        id="unload-session"
        phx-click={@on_unload}
        disabled={@pending?}
        class="btn btn-sm"
      >
        <.icon name="icon-log-out" class="size-3.5" /> Unload from tracer
      </button>

      <.tooltip :if={!@active? and !@other_node? and @busy?} id="load-busy-tip" position="bottom">
        <button type="button" id="load-session" aria-disabled="true" class="btn btn-sm">
          <.icon name="icon-log-in" class="size-3.5" /> Load into tracer
        </button>
        <:content>Stop the running session first</:content>
      </.tooltip>

      <button
        :if={!@active? and !@other_node? and !@busy?}
        type="button"
        id="load-session"
        phx-click={@on_load}
        disabled={@pending?}
        class="btn btn-sm"
      >
        <.icon name="icon-log-in" class="size-3.5" /> Load into tracer
      </button>

      <.tooltip :if={!@active? and @other_node? and @busy?} id="copy-busy-tip" position="bottom">
        <button type="button" id="trace-here" aria-disabled="true" class="btn btn-sm">
          <.icon name="icon-copy" class="size-3.5" /> Trace on this node
        </button>
        <:content>Stop the running session first</:content>
      </.tooltip>

      <.tooltip
        :if={!@active? and @other_node? and !@busy?}
        id="trace-here-tip"
        position="bottom"
      >
        <button
          type="button"
          id="trace-here"
          phx-click={@on_copy}
          disabled={@pending?}
          class="btn btn-sm"
        >
          <.icon name="icon-copy" class="size-3.5" /> Trace on this node
        </button>
        <:content>New session on {@connected_node} with these parameters</:content>
      </.tooltip>

      <.tooltip :if={!@active?} id="delete-session-tip" position="bottom">
        <button
          type="button"
          id="delete-session"
          phx-click={@on_delete}
          disabled={@pending?}
          aria-label="Delete session"
          class="btn btn-sm btn-square btn-ghost text-base-content/60 hover:bg-error/10 hover:text-error"
        >
          <.icon name="icon-trash" class="size-3.5" />
        </button>
        <:content>Delete session</:content>
      </.tooltip>

      <.link navigate={@open_href} id="open-session" class="btn btn-sm btn-primary">
        Open session <.icon name="icon-arrow-right" class="size-3.5" />
      </.link>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :saved?, :boolean, required: true
  attr :runtime_seconds, :integer, required: true
  attr :storage_limit_mb, :integer, required: true

  defp overview_totals(assigns) do
    limit_bytes = assigns.storage_limit_mb * 1_000_000

    assigns =
      assign(assigns,
        limit_bytes: limit_bytes,
        storage_pct: storage_percent(assigns.item.bytes, limit_bytes)
      )

    ~H"""
    <div
      id="overview-totals"
      class="bg-base-200 border-base-200 rounded-b-box grid grid-cols-2 gap-px overflow-hidden border-t lg:grid-cols-4"
    >
      <.total_cell
        id="total-traces"
        label="Traces"
        value={Formatters.format_integer(@item.traces)}
        unit="all runs"
      />
      <.total_cell
        id="total-dropped"
        label="Dropped"
        value={Formatters.format_integer(@item.dropped)}
        value_class={@item.dropped > 0 && "text-warning"}
      />
      <.total_cell
        id="total-runs"
        label="Runs"
        value={Formatters.format_integer(max(@item.runs, 1))}
        unit={"#{TracingComponents.format_elapsed(@runtime_seconds)} run time"}
      />
      <.total_cell
        :if={@saved?}
        id="total-storage"
        label="Storage"
        value={TracingComponents.format_storage_bytes(@item.bytes)}
        unit={"of #{TracingComponents.format_storage_bytes(@limit_bytes)}"}
        bar={@storage_pct}
      />
      <.total_cell
        :if={!@saved?}
        id="total-storage"
        label="Storage"
        value="Not saved"
        unit={"newest #{Tracer.kept_traces()}"}
        prose
      />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :overview, :map, required: true

  def overview_charts(assigns) do
    saved? = item_saved?(assigns.item)
    functions = top_function_rows(assigns.item.config, assigns.overview.summary)

    assigns =
      assign(assigns,
        saved?: saved?,
        activity_aside:
          if(saved?, do: "traces over all runs", else: "newest #{Tracer.kept_traces()}"),
        functions: functions
      )

    ~H"""
    <.overview_runs_card :if={@overview.runs != []} runs={@overview.runs} />
    <div class="grid flex-none gap-4 xl:grid-cols-2">
      <.overview_activity_card buckets={@overview.activity} aside={@activity_aside} />
      <.overview_outcome_card item={@item} summary={@overview.summary} />
    </div>
    <.overview_functions_card
      :if={@functions != []}
      functions={@functions}
      total_calls={@overview.summary.calls}
    />
    """
  end

  attr :runs, :list, required: true

  defp overview_runs_card(assigns) do
    max_ms = assigns.runs |> Enum.map(&max(&1.duration_ms, 1)) |> Enum.max(fn -> 1 end)
    assigns = assign(assigns, :max_ms, max_ms)

    ~H"""
    <.chart_card
      id="overview-runs"
      title="Runs"
      aside={TracingComponents.count(length(@runs), "run", "runs")}
    >
      <%= for run <- @runs do %>
        <div
          :if={run.previous_config}
          class="font-mono text-base-content/60 flex items-center gap-1.5 pl-16 text-xs"
        >
          <.icon name="icon-pencil" class="size-3 shrink-0" />
          <span>
            <TracingComponents.config_changes config={run.config} previous={run.previous_config} />
          </span>
        </div>
        <div id={"overview-run-#{run.index}"} class="flex items-center gap-3 text-sm">
          <span class="font-mono text-base-content/60 w-13 shrink-0">Run {run.index}</span>
          <div class="bg-base-content/10 h-2.5 min-w-0 flex-1 overflow-hidden rounded-full">
            <span
              class={[
                "block h-full rounded-full",
                run_fill_class(run_tone(run.reason)),
                run.reason == :running && "animate-pulse"
              ]}
              style={"width: #{max(div(max(run.duration_ms, 1) * 100, @max_ms), 3)}%"}
            ></span>
          </div>
          <span class="font-mono text-base-content w-20 shrink-0 text-right tabular-nums">
            {Formatters.format_integer(run.traces)}
          </span>
          <span class="font-mono text-base-content/60 w-12 shrink-0 text-right tabular-nums">
            {TracingComponents.format_elapsed(div(run.duration_ms, 1_000))}
          </span>
          <span class={[
            "w-44 shrink-0 truncate",
            TracingComponents.tone_class(run_tone(run.reason), :label)
          ]}>
            {run_reason_label(run.reason)}
          </span>
          <.icon
            name={origin_icon(run.origin)}
            title={"Started from #{origin_label(run.origin)}"}
            class="text-base-content/40 size-4 shrink-0"
          />
        </div>
      <% end %>
    </.chart_card>
    """
  end

  attr :buckets, :list, required: true
  attr :aside, :string, required: true

  defp overview_activity_card(assigns) do
    max_val =
      assigns.buckets
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> max(1)

    assigns = assign(assigns, :max_val, max_val)

    ~H"""
    <.chart_card id="overview-activity" title="Activity" aside={@aside}>
      <%= if @buckets == [] do %>
        <p class="font-mono text-base-content/50 py-6 text-center text-xs">No traces captured</p>
      <% else %>
        <div class="flex h-28 items-end gap-0.5" aria-hidden="true">
          <%= for bucket <- @buckets do %>
            <%= if is_nil(bucket) do %>
              <span class="border-base-content/20 mx-1 h-full border-l border-dashed"></span>
            <% else %>
              <span
                class="bg-primary rounded-xs opacity-55 flex-1 transition-opacity hover:opacity-100"
                style={"height: #{if bucket == 0, do: 2, else: max(div(bucket * 100, @max_val), 4)}%"}
                title={TracingComponents.count(bucket, "trace", "traces")}
              ></span>
            <% end %>
          <% end %>
        </div>
        <div class="font-mono text-base-content/60 flex justify-between text-xs">
          <span>first trace</span>
          <span>last trace</span>
        </div>
      <% end %>
    </.chart_card>
    """
  end

  attr :item, :map, required: true
  attr :summary, Summary, required: true

  defp overview_outcome_card(assigns) do
    total = max(assigns.summary.calls + assigns.summary.returns + assigns.summary.exceptions, 1)

    returns_traced? =
      (assigns.item.config != nil and assigns.item.config.return_trace) or
        assigns.summary.returns > 0 or assigns.summary.exceptions > 0

    assigns =
      assign(assigns,
        total: total,
        returns_traced?: returns_traced?,
        process_count: map_size(assigns.summary.processes)
      )

    ~H"""
    <.chart_card id="overview-outcome" title="Outcome">
      <div class="bg-base-content/10 flex h-3 gap-px overflow-hidden rounded-full">
        <span
          :if={@summary.calls > 0}
          class="bg-primary opacity-55 block h-full"
          style={"width: #{@summary.calls * 100 / @total}%"}
        ></span>
        <span
          :if={@summary.returns > 0}
          class="bg-success block h-full opacity-70"
          style={"width: #{@summary.returns * 100 / @total}%"}
        ></span>
        <span
          :if={@summary.exceptions > 0}
          class="bg-error block h-full"
          style={"width: #{@summary.exceptions * 100 / @total}%"}
        ></span>
      </div>

      <div class="font-mono text-base-content/60 flex flex-wrap gap-x-5 gap-y-1 text-sm">
        <.outcome_legend label="Calls" count={@summary.calls} dot_class="bg-primary opacity-55" />
        <%= if @returns_traced? do %>
          <.outcome_legend
            label="Returns"
            count={@summary.returns}
            dot_class="bg-success opacity-70"
          />
          <.outcome_legend label="Exceptions" count={@summary.exceptions} dot_class="bg-error" />
        <% else %>
          <span>Returns not traced</span>
        <% end %>
      </div>

      <div class="border-base-200 font-mono flex items-baseline justify-between border-t pt-3 text-sm">
        <span class="text-base-content/60">Processes</span>
        <span id="outcome-processes" class="text-base-content tabular-nums">
          {Formatters.format_integer(@process_count)}
        </span>
      </div>
    </.chart_card>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :dot_class, :string, required: true

  defp outcome_legend(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span class={["size-2.5 rounded-full", @dot_class]}></span>
      {@label}
      <span class="text-base-content tabular-nums">{Formatters.format_integer(@count)}</span>
    </span>
    """
  end

  attr :functions, :list, required: true
  attr :total_calls, :integer, required: true

  defp overview_functions_card(assigns) do
    {_, max_count, _} = List.first(assigns.functions)
    assigns = assign(assigns, :max_count, max(max_count, 1))

    ~H"""
    <.chart_card
      id="overview-functions"
      title="Top functions"
      aside={"of #{TracingComponents.count(@total_calls, "call", "calls")}"}
    >
      <div
        :for={{label, count, other?} <- @functions}
        class="grid-cols-[11rem_1fr_5rem] grid items-center gap-3 text-sm"
      >
        <span class="font-mono text-base-content truncate" title={label}>{label}</span>
        <div class="bg-base-content/10 h-2 overflow-hidden rounded-full">
          <span
            class={[
              "block h-full rounded-full",
              if(other?, do: "bg-base-content/30", else: "bg-primary opacity-55")
            ]}
            style={"width: #{max(div(count * 100, @max_count), 2)}%"}
          ></span>
        </div>
        <span class="font-mono text-base-content/70 text-right tabular-nums">
          {Formatters.format_integer(count)}
        </span>
      </div>
    </.chart_card>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :aside, :string, default: nil
  slot :inner_block, required: true

  defp chart_card(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 flex-none border shadow-sm">
      <div class="flex items-baseline justify-between gap-3 px-5 pt-4 pb-3">
        <h3 class="text-base-content text-base font-semibold">{@title}</h3>
        <span :if={@aside} class="font-mono text-base-content/60 text-xs">{@aside}</span>
      </div>
      <div class="flex flex-col gap-3 px-5 pb-5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :unit, :string, default: nil
  attr :bar, :integer, default: nil
  attr :value_class, :any, default: nil
  attr :prose, :boolean, default: false

  defp total_cell(assigns) do
    ~H"""
    <div id={@id} class="bg-base-100 min-w-0 px-5 py-4">
      <div class="font-mono tracking-label text-base-content/60 mb-1.5 text-xs font-semibold uppercase">
        {@label}
      </div>
      <div class="min-h-7 flex items-baseline gap-1.5">
        <span class={[
          "truncate text-lg font-semibold",
          !@prose && "font-mono tabular-nums",
          @value_class
        ]}>
          {@value}
        </span>
        <span :if={@unit} class="font-mono text-base-content/60 shrink-0 text-xs">{@unit}</span>
      </div>
      <div :if={@bar != nil} class="bg-base-content/10 mt-2 flex h-1.5 overflow-hidden rounded-full">
        <span class="bg-primary block h-full transition-all" style={"width: #{@bar}%"}></span>
      </div>
    </div>
    """
  end

  @spec item_node(Session.t() | map()) :: String.t() | nil
  def item_node(%Session{node: nil}), do: nil
  def item_node(%Session{node: node}), do: Atom.to_string(node)
  def item_node(%{node: node}), do: node

  @spec item_other_node?(Session.t() | map(), String.t()) :: boolean()
  def item_other_node?(item, connected_node) do
    case item_node(item) do
      nil -> false
      node -> node != connected_node
    end
  end

  @spec item_tone(Session.t() | map()) :: TracingComponents.tone()
  def item_tone(%Session{} = session), do: TracingComponents.tone(session)
  def item_tone(%{status: :running}), do: :running

  def item_tone(%{status: :stopped, stop_reason: reason}),
    do: TracingComponents.reason_tone(reason)

  def item_tone(_item), do: :open

  @spec origin_icon(:ui | :mcp) :: String.t()
  def origin_icon(:mcp), do: "icon-brain"
  def origin_icon(_origin), do: "icon-laptop"

  @spec origin_label(:ui | :mcp) :: String.t()
  def origin_label(:mcp), do: "MCP"
  def origin_label(_origin), do: "UI"

  @spec item_mfa_parts(Config.t() | nil) :: {String.t(), String.t()}
  def item_mfa_parts(nil), do: {"", "New session"}
  def item_mfa_parts(%Config{} = config), do: TracingComponents.traced_mfa_parts(config)

  @spec storage_percent(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def storage_percent(bytes, limit) when limit > 0 and bytes > 0,
    do: min(max(div(bytes * 100, limit), 1), 100)

  def storage_percent(_bytes, _limit), do: 0

  defp sorted_nodes(counts, connected_node) do
    counts
    |> Map.put_new(connected_node, 0)
    |> Enum.sort_by(fn {node, _count} -> {node != connected_node, node} end)
  end

  defp tile_frame_class(true, true, _tone, _selected?),
    do: "border " <> TracingComponents.tone_class(:other_node, :chip)

  defp tile_frame_class(true, false, :running, _selected?),
    do: "border " <> TracingComponents.tone_class(:running, :chip)

  defp tile_frame_class(true, false, _tone, _selected?),
    do: "border " <> TracingComponents.tone_class(:open, :chip)

  defp tile_frame_class(false, _other_node?, _tone, true), do: "border border-transparent"

  defp tile_frame_class(false, _other_node?, _tone, false),
    do: "border border-transparent hover:bg-base-200"

  defp tile_state_label(%{status: :running}), do: "Running"
  defp tile_state_label(%{config: nil}), do: "Ready · no parameters yet"
  defp tile_state_label(%{status: :idle}), do: "Ready"

  defp tile_state_label(%{stop_reason: reason}) when not is_nil(reason),
    do: TracingComponents.stop_reason_label(reason)

  defp tile_state_label(_item), do: "Stopped"

  defp tile_meta(%{status: :idle}), do: "not run yet"

  defp tile_meta(%{traces: traces, runs: runs}) when runs > 1,
    do: "#{TracingComponents.count(traces, "trace", "traces")} · #{runs} runs"

  defp tile_meta(%{traces: traces}),
    do: TracingComponents.count(traces, "trace", "traces")

  defp tile_ago(%{status: :running}, _now), do: "now"

  defp tile_ago(item, now) do
    ref = item.stopped_at || item.started_at || item.created_at
    seconds = max(DateTime.diff(now, ref, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      seconds < 172_800 -> "yesterday"
      true -> "#{div(seconds, 86_400)} days ago"
    end
  end

  defp empty_title("all", _connected_node), do: "No saved sessions yet"
  defp empty_title(node, node), do: "No sessions on this node yet"
  defp empty_title(node, _connected_node), do: "No sessions on #{node} yet"

  defp item_saved?(%Session{save: save}), do: save
  defp item_saved?(_listed), do: true

  defp overview_state_label(%{status: :running}), do: "Running"
  defp overview_state_label(%{status: :idle}), do: "Ready"
  defp overview_state_label(_item), do: "Stopped"

  defp overview_meta_lead(%Session{status: :running, run_started_at: %DateTime{} = at}, true),
    do: "Active in tracer · started #{Formatters.format_time(at)} UTC"

  defp overview_meta_lead(%Session{config: nil}, true),
    do: "Active in tracer · no parameters yet"

  defp overview_meta_lead(%Session{status: :idle}, true),
    do: "Active in tracer · not started"

  defp overview_meta_lead(%Session{save: false}, true),
    do: "Active in tracer · not saved"

  defp overview_meta_lead(%Session{stop_reason: reason}, true) when not is_nil(reason),
    do: "Active in tracer · #{String.downcase(TracingComponents.stop_reason_label(reason))}"

  defp overview_meta_lead(%Session{}, true), do: "Active in tracer · stopped"

  defp overview_meta_lead(item, false) do
    reason =
      if item.stop_reason,
        do: TracingComponents.stop_reason_label(item.stop_reason),
        else: "Stopped"

    recorded =
      case item.started_at || item.created_at do
        %DateTime{} = at -> Calendar.strftime(at, "%-d %b %H:%M UTC")
        _ -> ""
      end

    "#{reason} · recorded #{recorded}"
  end

  defp run_tone(:running), do: :running
  defp run_tone(reason), do: TracingComponents.reason_tone(reason)

  defp run_reason_label(:running), do: "Running"
  defp run_reason_label(reason), do: TracingComponents.stop_reason_label(reason)

  defp run_fill_class(:running), do: "bg-success opacity-70"
  defp run_fill_class(:warning), do: "bg-warning opacity-70"
  defp run_fill_class(:error), do: "bg-error opacity-70"
  defp run_fill_class(:open), do: "bg-primary opacity-55"

  @top_functions_limit 5

  defp top_function_rows(config, %Summary{functions: functions}) do
    wildcard? = match?(%Config{function: "_"}, config) or match?(%Config{arity: nil}, config)

    if map_size(functions) == 0 or (not wildcard? and map_size(functions) <= 1) do
      []
    else
      sorted = Enum.sort_by(functions, fn {_mfa, calls} -> -calls end)
      {top, rest} = Enum.split(sorted, @top_functions_limit)
      same_mod? = single_module?(sorted)

      rows =
        Enum.map(top, fn {mfa, calls} ->
          {format_top_mfa(mfa, same_mod?), calls, false}
        end)

      case rest do
        [] ->
          rows

        others ->
          other_calls = others |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          rows ++ [{"others (#{length(others)})", other_calls, true}]
      end
    end
  end

  defp single_module?(entries) do
    entries
    |> Enum.map(fn {{mod, _fun, _arity}, _calls} -> mod end)
    |> Enum.uniq()
    |> length() == 1
  end

  defp format_top_mfa({mod, fun, arity}, true) do
    {_mod_part, fun_part} =
      TermFormatter.mfa_pattern_parts(Atom.to_string(mod), Atom.to_string(fun), arity)

    fun_part
  end

  defp format_top_mfa(mfa, false), do: TermFormatter.format_mfa(mfa)
end
