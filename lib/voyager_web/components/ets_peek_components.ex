defmodule VoyagerWeb.Components.EtsPeekComponents do
  @moduledoc """
  The ETS contents page: the table info panel, the gated fetch controls, the
  paginated record list and the lookup sidebar.
  """

  use VoyagerWeb, :component

  alias Voyager.Pid
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.DetailsPanelComponents
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.EtsTableHelp
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsLookupControls
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"
  @key_marker :"$voyager_key"

  @budget_help "Caps how much of each fetched term the remote node sends back — " <>
                 "roughly one unit per subterm, binaries charged per byte kept. " <>
                 "Anything beyond the budget is truncated on the remote."

  @records_timeout_help "How long to wait for the node to read a page of records before the fetch fails."
  @lookup_timeout_help "How long to wait for the node to look up this key before the lookup fails."

  @preview_opts [
    limit: 20,
    printable_limit: 128,
    width: :infinity,
    inspect_fun: &Pid.inspect_fun/2
  ]

  attr :table_name, :string, required: true
  attr :node_name, :string, required: true
  attr :back_href, :string, required: true
  attr :last_updated, :any, default: nil

  def header(assigns) do
    ~H"""
    <.node_header
      node_name={@node_name}
      last_updated={@last_updated}
      waiting_message={nil}
      class="mb-0"
    >
      <:actions>
        <.tooltip id="ets-table-name-tip" position="bottom" interactive tip_class="font-mono">
          <h2
            id="ets-table-name"
            class="text-base-content font-mono flex min-w-0 items-center gap-2 text-2xl font-bold tracking-tight"
          >
            <span class="truncate">{@table_name}</span>
          </h2>
          <:content>
            <div class="flex items-center gap-1">
              <span id="ets-table-name-text" class="break-all">{@table_name}</span>
              <.copy_button
                id="ets-table-name-copy"
                target="#ets-table-name-text"
                icon_only
                label="Copy table name"
                class="btn-xs text-base-content/50 shrink-0 hover:text-base-content"
              />
            </div>
          </:content>
        </.tooltip>
      </:actions>
    </.node_header>

    <.link id="back-to-ets-tables" navigate={@back_href} class="btn btn-ghost btn-sm w-max gap-2">
      <.icon name="icon-arrow-left" class="size-4" /> ETS Tables
    </.link>
    """
  end

  attr :info, :map, required: true
  attr :current_url, :string, required: true

  def info_panel(assigns) do
    ~H"""
    <dl
      id="ets-table-info"
      class="border-base-200 bg-base-100 grid grid-cols-2 gap-x-6 gap-y-3 rounded-lg border p-4 sm:grid-cols-3 lg:grid-cols-5"
    >
      <.info_item label="Type" help={:type}>
        <span class="badge badge-sm badge-ghost font-mono">{@info.type}</span>
      </.info_item>
      <.info_item label="Protection" help={:protection}>
        <EtsTableComponents.private_badge
          :if={@info.protection == :private}
          id="ets-info-protection"
          size={:sm}
        />
        <span :if={@info.protection != :private} class="font-mono text-base-content/70">
          {@info.protection}
        </span>
      </.info_item>
      <.info_item id="ets-info-keypos" label="Key position" help={:keypos}>{@info.keypos}</.info_item>
      <.info_item label="Objects" help={:size}>{Formatters.format_integer(@info.size)}</.info_item>
      <.info_item label="Memory" help={:memory}>{Formatters.format_bytes(@info.memory)}</.info_item>
      <.info_item id="ets-info-owner" label="Owner" help={:owner}>
        <ProcessComponents.process_link pid={@info.owner} current_url={@current_url} />
      </.info_item>
      <.info_item :if={@info.heir == :none} label="Heir" help={:heir}>none</.info_item>
      <.info_item :if={@info.heir != :none} label="Heir" help={:heir}>
        <ProcessComponents.process_link pid={@info.heir} current_url={@current_url} />
      </.info_item>
      <.info_item label="Named table" help={:named_table}>
        {EtsTableComponents.format_flag(@info.named_table)}
      </.info_item>
      <.info_item label="Compressed" help={:compressed}>
        {EtsTableComponents.format_flag(@info.compressed)}
      </.info_item>
      <.info_item label="Read concurrency" help={:read_concurrency}>
        {EtsTableComponents.format_flag(@info.read_concurrency)}
      </.info_item>
      <.info_item label="Write concurrency" help={:write_concurrency}>
        {EtsTableComponents.format_flag(@info.write_concurrency)}
      </.info_item>
      <.info_item
        :if={Map.has_key?(@info, :decentralized_counters)}
        label="Decentralized counters"
        help={:decentralized_counters}
      >
        {EtsTableComponents.format_flag(@info.decentralized_counters)}
      </.info_item>
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :help, :atom, required: true, doc: "`EtsTableHelp` key"
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp info_item(assigns) do
    assigns = assign(assigns, :entry, EtsTableHelp.get(assigns.help))

    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-0.5">
      <dt class="text-base-content/60 flex h-6 items-center gap-1 text-xs">
        {@label}
        <.help_tooltip id={"ets-info-help-#{@help}"} entry={@entry} />
      </dt>
      <dd class="font-mono text-base-content truncate text-xs">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :loading?, :boolean, default: false
  attr :readable?, :boolean, default: true
  attr :fetched?, :boolean, default: false

  def controls(assigns) do
    assigns =
      assigns
      |> assign(:budget_help, @budget_help)
      |> assign(:records_timeout_help, @records_timeout_help)

    ~H"""
    <.form for={@form} id="ets-peek-controls" phx-change="validate" class="flex flex-col gap-1">
      <fieldset
        disabled={@loading? or not @readable?}
        class={["contents", (@loading? or not @readable?) && "opacity-60"]}
      >
        <div class="grid-cols-[auto_auto_auto] grid-rows-[auto_auto_auto] grid w-max items-center gap-x-3">
          <.field_label field={@form[:budget]} label="Record budget" help={@budget_help} />
          <.field_label field={@form[:timeout]} label="Timeout (ms)" help={@records_timeout_help} />
          <span />

          <.number_input
            field={@form[:budget]}
            bounds={EtsPeekControls.budget_bounds()}
            class="w-28"
          />
          <.number_input field={@form[:timeout]} bounds={EtsPeekControls.timeout_bounds()} />

          <button
            id="ets-peek-fetch"
            type="button"
            phx-click="fetch"
            disabled={@loading? or not @readable?}
            class="btn btn-primary btn-sm gap-2"
          >
            <span :if={@loading?} class="loading loading-spinner loading-xs" />
            {if @fetched?, do: "Reload snapshot", else: "Fetch records"}
          </button>

          <.field_error field={@form[:budget]} />
          <.field_error field={@form[:timeout]} />
          <span />
        </div>
      </fieldset>
    </.form>
    """
  end

  def truncation_notice(assigns) do
    ~H"""
    <div id="ets-truncation-notice" role="note" class="alert alert-warning text-xs">
      <.icon name="icon-circle-alert" class="text-warning size-4 shrink-0" />
      <span>
        Some records were shortened on the node to fit the term budget. Paging is
        best-effort: the table can change between pages.
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :records, :list, required: true
  attr :term_states, :map, required: true
  attr :open_rows, :any, required: true
  attr :offset, :integer, default: 0
  attr :keypos, :integer, default: 1

  def records(assigns) do
    ~H"""
    <ol id={@id} class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
      <li
        :for={{record, index} <- Enum.with_index(@records)}
        id={"#{@id}-#{index}"}
        class="border-base-200 bg-base-100 rounded-lg border"
      >
        <div class="flex items-center gap-2 px-3 py-2">
          <button
            id={"#{@id}-#{index}-toggle"}
            type="button"
            phx-click="toggle_row"
            phx-value-index={index}
            aria-expanded={to_string(row_open?(@open_rows, index))}
            class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded text-left opacity-80"
          >
            <.icon
              name="icon-chevron-right"
              class={[
                "text-base-content/50 size-3.5 shrink-0 transition-transform",
                row_open?(@open_rows, index) && "rotate-90"
              ]}
            />
            <span class="text-base-content/50 font-mono shrink-0 text-xs tabular-nums">
              {@offset + index + 1}
            </span>
            <span class="font-mono text-base-content min-w-0 flex-1 truncate text-xs">
              <span
                :for={{text, key?} <- preview_parts(record, @keypos)}
                id={key? && "#{@id}-#{index}-key"}
                class={key? && "text-primary font-bold"}
              >{text}</span>
            </span>
            <.tooltip
              :if={truncated_record?(record)}
              id={"#{@id}-#{index}-truncated"}
              class="shrink-0"
            >
              <.icon name="icon-circle-alert" class="text-warning size-3.5" />
              <:content>This record was shortened to fit the term budget</:content>
            </.tooltip>
          </button>

          <.lookup_button
            :if={lookup_key(record, @keypos) != :error}
            id={"#{@id}-#{index}-lookup"}
            index={index}
          />
          <.tooltip
            :if={lookup_key(record, @keypos) == :error}
            id={"#{@id}-#{index}-lookup-tip"}
            class="shrink-0 cursor-not-allowed"
          >
            <.lookup_button id={"#{@id}-#{index}-lookup"} index={index} disabled />
            <:content>Key was truncated</:content>
          </.tooltip>
        </div>

        <div :if={row_open?(@open_rows, index)} class="border-base-200 border-t px-3 py-2">
          <TermComponents.term_inspector
            id={record_inspector_id(@id, index)}
            term={record}
            state={@term_states[record_inspector_id(@id, index)] || %State{}}
            class="overflow-x-auto"
          />
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :index, :integer, required: true
  attr :disabled, :boolean, default: false

  defp lookup_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={if(!@disabled, do: "open_sidebar")}
      phx-value-index={@index}
      aria-disabled={if(@disabled, do: "true")}
      aria-label={if(@disabled, do: "Lookup unavailable: key was truncated")}
      title={if(!@disabled, do: "Look up every record with this key")}
      class="btn btn-ghost btn-xs text-base-content/60 shrink-0 gap-1 aria-disabled:opacity-50 hover:text-primary"
    >
      <.icon name="icon-panel-left" class="size-3.5 -scale-x-100" /> Lookup
    </button>
    """
  end

  attr :key, :any, required: true
  attr :lookup, Phoenix.LiveView.AsyncResult, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :term_states, :map, required: true
  attr :error_message, :string, default: nil
  attr :page, :integer, required: true, doc: "0-based"
  attr :page_size, :integer, required: true
  attr :total, :integer, required: true
  attr :page_size_options, :list, required: true

  def sidebar(assigns) do
    assigns =
      assigns
      |> assign(:budget_help, @budget_help)
      |> assign(:lookup_timeout_help, @lookup_timeout_help)

    ~H"""
    <aside
      id="ets-lookup-sidebar"
      phx-hook="DetailsPanelResize"
      data-resize-persist="false"
      class="details-panel border-base-200 bg-base-100 absolute inset-y-0 right-0 z-40 flex h-full min-h-0 w-full flex-col border-l p-4 shadow-2xl"
    >
      <DetailsPanelComponents.resize_handle panel_id="ets-lookup-sidebar" open?={true} />
      <div class="flex min-h-0 flex-1 flex-col gap-4 overflow-hidden">
        <div class="border-base-200 flex shrink-0 items-start gap-3 border-b pb-3">
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <div class="flex items-center gap-2">
              <.icon name="icon-database-search" class="text-primary size-3.5" />
              <div class="font-mono text-base-content text-xs uppercase">Key lookup</div>
            </div>
            <DetailsPanelComponents.copyable
              id="ets-sidebar-key"
              class="font-mono text-base-content break-all text-sm font-medium"
              text={inspect(@key, inspect_fun: &Pid.inspect_fun/2)}
              label="Copy key"
            />
          </div>
          <DetailsPanelComponents.close_button
            panel_id="ets-lookup-sidebar"
            on_close="close-details-panel"
          />
        </div>

        <.form
          for={@form}
          id="ets-lookup-controls"
          phx-change="validate_lookup"
          class="flex shrink-0 flex-col gap-1"
        >
          <div class="grid-cols-[auto_auto_auto] grid-rows-[auto_auto_auto] grid w-max items-center gap-x-3">
            <.field_label field={@form[:budget]} label="Term budget" help={@budget_help} />
            <.field_label field={@form[:timeout]} label="Timeout (ms)" help={@lookup_timeout_help} />
            <span />

            <.number_input field={@form[:budget]} bounds={{EtsLookupControls.min_budget(), nil}} />
            <.number_input field={@form[:timeout]} bounds={EtsLookupControls.timeout_bounds()} />

            <button
              id="ets-lookup-refetch"
              type="button"
              phx-click="refetch_lookup"
              disabled={@lookup.loading != nil}
              class="btn btn-primary btn-sm gap-2"
            >
              <span :if={@lookup.loading != nil} class="loading loading-spinner loading-xs" /> Refetch
            </button>

            <.field_error field={@form[:budget]} />
            <.field_error field={@form[:timeout]} />
            <span />
          </div>
        </.form>

        <.error_state :if={@error_message} id="ets-lookup-error" message={@error_message} />

        <.async_result :let={chunk} assign={@lookup}>
          <:loading>
            <.loading_state id="ets-lookup-loading" message="Looking up key…" />
          </:loading>

          <p :if={chunk.records == []} id="ets-lookup-empty" class="text-base-content/70 text-sm">
            {if @page == 0,
              do: "No records with this key. They may have been deleted.",
              else: "No more records for this key. They may have been deleted since the last page."}
          </p>

          <div
            :if={chunk.records != []}
            id="ets-lookup-records"
            class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto"
          >
            <div
              :for={{record, index} <- Enum.with_index(chunk.records)}
              id={"ets-lookup-record-#{index}"}
              class="border-base-200 flex shrink-0 items-start gap-2 rounded-lg border p-3"
            >
              <TermComponents.term_inspector
                id={lookup_inspector_id(index)}
                term={record}
                state={@term_states[lookup_inspector_id(index)] || %State{}}
                class="text-sm! min-w-0 flex-1 overflow-x-auto"
              />
              <.copy_button
                id={"ets-lookup-record-#{index}-copy"}
                target={"#ets-lookup-record-#{index}-copy-source"}
                label="Copy record"
                icon_only
                size={:sm}
                class="text-base-content/60 shrink-0 hover:text-primary"
              />
              <span id={"ets-lookup-record-#{index}-copy-source"} hidden>{TermTree.copy_string(record)}</span>
            </div>
          </div>

          <p :if={chunk.truncated?} id="ets-lookup-truncated" class="text-base-content/50 text-xs">
            Shortened to fit the term budget — raise it and refetch to see more.
          </p>

          <DataTableComponents.pager
            :if={chunk.records != [] or @page > 0}
            id="ets-lookup-pager"
            page={@page + 1}
            page_size={@page_size}
            total={@total}
            page_size_options={@page_size_options}
            paginate_event="paginate_lookup"
            page_size_event="set_lookup_page_size"
          />
        </.async_result>
      </div>
    </aside>
    """
  end

  @spec record_inspector_id(String.t(), non_neg_integer()) :: String.t()
  def record_inspector_id(prefix, index), do: "#{prefix}-#{index}-term"

  @spec lookup_inspector_id(non_neg_integer()) :: String.t()
  def lookup_inspector_id(index), do: "ets-lookup-#{index}-term"

  @doc """
  The lookup key at `keypos`, or `:error` when the record is not a plain tuple
  or the key was cut by the term budget — a truncated key would look up a
  record that does not exist.
  """
  @spec lookup_key(term(), pos_integer()) :: {:ok, term()} | :error
  def lookup_key(record, keypos) when is_tuple(record) and tuple_size(record) >= keypos do
    key = elem(record, keypos - 1)
    if truncated_record?(key), do: :error, else: {:ok, key}
  end

  def lookup_key(_record, _keypos), do: :error

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :help, :string, default: nil

  defp field_label(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <label for={@field.id} class="text-base-content/70 text-xs font-medium">{@label}</label>
      <.help_tooltip :if={@help} id={"#{@field.id}-help"} text={@help} />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :bounds, :any, required: true, doc: "`{min, max}`; a nil max leaves the field unbounded"
  attr :class, :any, default: "w-26"

  defp number_input(assigns) do
    ~H"""
    <input
      id={@field.id}
      type="number"
      name={@field.name}
      value={@field.value}
      min={elem(@bounds, 0)}
      max={elem(@bounds, 1)}
      step="100"
      inputmode="numeric"
      phx-debounce="500"
      class={[
        "input input-sm input-bordered no-spinner font-mono",
        @class,
        @field.errors != [] && "input-error"
      ]}
    />
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_error(assigns) do
    ~H"""
    <p class="font-mono text-error relative w-24 text-xs">
      <span class="left-0">
        {@field.errors |> Enum.map_join(", ", &translate_error/1)}
      </span>
    </p>
    """
  end

  defp row_open?(open_rows, index), do: MapSet.member?(open_rows, index)

  defp truncated_record?(@truncated), do: true

  defp truncated_record?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&truncated_record?/1)
  end

  defp truncated_record?([head | tail]), do: truncated_record?(head) or truncated_record?(tail)

  defp truncated_record?(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.any?(fn {key, value} -> truncated_record?(key) or truncated_record?(value) end)
  end

  defp truncated_record?(_other), do: false

  # The marker spends less inspect limit than the key, so only the text before it is trusted.
  defp preview_parts(record, keypos) when is_tuple(record) and tuple_size(record) >= keypos do
    text = preview(record)
    marked = record |> put_elem(keypos - 1, @key_marker) |> preview()
    through_key = record |> Tuple.to_list() |> Enum.take(keypos) |> List.to_tuple() |> preview()
    key_end = byte_size(through_key) - 1

    with [before, _rest] <- String.split(marked, inspect(@key_marker), parts: 2),
         key_start = byte_size(before),
         <<head::binary-size(^key_start), key::binary-size(^key_end - ^key_start), tail::binary>> <-
           text do
      [{head, false}, {key, true}, {tail, false}]
    else
      _other -> [{text, false}]
    end
  end

  defp preview_parts(record, _keypos), do: [{preview(record), false}]

  defp preview(record) do
    record
    |> strip_markers()
    |> inspect(@preview_opts)
  rescue
    _e -> inspect(record, @preview_opts)
  end

  defp strip_markers(@truncated), do: :...
  defp strip_markers({@truncated, :binary, prefix, _size}), do: {prefix, :...}

  defp strip_markers(list) when is_list(list), do: Enum.map(list, &strip_markers/1)

  defp strip_markers(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&strip_markers/1) |> List.to_tuple()
  end

  defp strip_markers(map) when is_map(map) do
    map |> Map.to_list() |> Map.new(fn {k, v} -> {strip_markers(k), strip_markers(v)} end)
  end

  defp strip_markers(other), do: other
end
