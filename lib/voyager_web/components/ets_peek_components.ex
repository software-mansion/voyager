defmodule VoyagerWeb.Components.EtsPeekComponents do
  @moduledoc """
  The ETS contents page: the table info panel, the gated fetch controls, the
  paginated record list and the lookup sidebar.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.Components.DetailsPanelComponents
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsLookupControls
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"

  @budget_help "Caps how much of each fetched term the remote node sends back — " <>
                 "roughly one unit per subterm, binaries charged per byte kept. " <>
                 "Anything beyond the budget is truncated on the remote."

  attr :table_name, :string, required: true
  attr :node_name, :string, required: true
  attr :back_href, :string, required: true

  def header(assigns) do
    ~H"""
    <.node_header node_name={@node_name} waiting_message={nil} class="mb-0">
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
  attr :owner_href, :string, required: true

  def info_panel(assigns) do
    ~H"""
    <dl
      id="ets-table-info"
      class="border-base-200 bg-base-100 grid grid-cols-2 gap-x-6 gap-y-3 rounded-lg border p-4 sm:grid-cols-3 lg:grid-cols-5"
    >
      <.info_item label="Type">
        <span class="badge badge-sm badge-ghost font-mono">{@info.type}</span>
      </.info_item>
      <.info_item label="Protection">
        <EtsTableComponents.private_badge
          :if={@info.protection == :private}
          id="ets-info-protection"
          size={:sm}
        />
        <span :if={@info.protection != :private} class="font-mono text-base-content/70">
          {@info.protection}
        </span>
      </.info_item>
      <.info_item id="ets-info-keypos" label="Key position">{@info.keypos}</.info_item>
      <.info_item label="Records">{Formatters.format_integer(@info.size)}</.info_item>
      <.info_item label="Memory">{Formatters.format_bytes(@info.memory)}</.info_item>
      <.info_item id="ets-info-owner" label="Owner">
        <DetailsPanelComponents.pid_chip
          href={@owner_href}
          label={Formatters.format_pid(@info.owner)}
        />
      </.info_item>
      <.info_item label="Heir">
        {if @info.heir == :none, do: "none", else: inspect(@info.heir)}
      </.info_item>
      <.info_item label="Named table">{@info.named_table}</.info_item>
      <.info_item label="Compressed">{@info.compressed}</.info_item>
      <.info_item label="Read concurrency">{@info.read_concurrency}</.info_item>
      <.info_item label="Write concurrency">{@info.write_concurrency}</.info_item>
      <.info_item :if={Map.has_key?(@info, :decentralized_counters)} label="Decentralized counters">
        {@info.decentralized_counters}
      </.info_item>
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp info_item(assigns) do
    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-0.5">
      <dt class="text-base-content/60 text-xs">{@label}</dt>
      <dd class="font-mono text-base-content truncate text-xs">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :loading?, :boolean, default: false
  attr :readable?, :boolean, default: true
  attr :fetched?, :boolean, default: false

  def controls(assigns) do
    assigns = assign(assigns, :budget_help, @budget_help)

    ~H"""
    <.form for={@form} id="ets-peek-controls" phx-change="validate" class="flex flex-col gap-1">
      <fieldset
        disabled={@loading? or not @readable?}
        class={["contents", (@loading? or not @readable?) && "opacity-60"]}
      >
        <div class="grid-cols-[auto_auto_auto] grid-rows-[auto_auto_auto] grid w-max items-center gap-x-3">
          <.field_label field={@form[:budget]} label="Budget per record" help={@budget_help} />
          <.field_label field={@form[:timeout]} label="Timeout (ms)" />
          <span />

          <.number_input field={@form[:budget]} bounds={EtsPeekControls.budget_bounds()} />
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
  attr :lookupable?, :boolean, default: false
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
              {preview(record)}
            </span>
            <span
              :if={truncated_record?(record)}
              id={"#{@id}-#{index}-truncated"}
              title="This record was shortened to fit the term budget"
              class="shrink-0"
            >
              <.icon name="icon-circle-alert" class="text-warning size-3.5" />
            </span>
          </button>

          <button
            :if={@lookupable? and lookup_key(record, @keypos) != :error}
            id={"#{@id}-#{index}-lookup"}
            type="button"
            phx-click="open_sidebar"
            phx-value-index={index}
            title="Look up this record"
            class="btn btn-ghost btn-xs text-base-content/60 shrink-0 gap-1 hover:text-primary"
          >
            <.icon name="icon-panel-left" class="size-3.5 -scale-x-100" /> Lookup
          </button>
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

  attr :key, :any, required: true
  attr :lookup, Phoenix.LiveView.AsyncResult, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :term_states, :map, required: true
  attr :error_message, :string, default: nil

  def sidebar(assigns) do
    assigns = assign(assigns, :budget_help, @budget_help)

    ~H"""
    <aside
      id="ets-lookup-sidebar"
      phx-hook="DetailsPanelResize"
      data-resize-persist="false"
      class="details-panel border-base-200 bg-base-100 absolute inset-y-0 right-0 z-40 flex w-full flex-col gap-4 border-l p-4 shadow-2xl"
    >
      <DetailsPanelComponents.resize_handle panel_id="ets-lookup-sidebar" open?={true} />
      <div class="border-base-200 flex items-start gap-3 border-b pb-3">
        <div class="flex min-w-0 flex-1 flex-col gap-1.5">
          <div class="flex items-center gap-2">
            <.icon name="icon-database-search" class="text-primary size-3.5" />
            <div class="font-mono text-base-content text-xs uppercase">Record lookup</div>
          </div>
          <DetailsPanelComponents.copyable
            id="ets-sidebar-key"
            class="font-mono text-base-content break-all text-sm font-medium"
            text={inspect(@key)}
            label="Copy key"
          />
        </div>
        <DetailsPanelComponents.close_button panel_id="ets-lookup-sidebar" />
      </div>

      <.form
        for={@form}
        id="ets-lookup-controls"
        phx-change="validate_lookup"
        class="flex flex-col gap-1"
      >
        <div class="grid-cols-[auto_auto_auto] grid-rows-[auto_auto_auto] grid w-max items-center gap-x-3">
          <.field_label field={@form[:budget]} label="Term budget" help={@budget_help} />
          <.field_label field={@form[:timeout]} label="Timeout (ms)" />
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

      <.async_result :let={chunk} assign={@lookup}>
        <:loading>
          <.loading_state id="ets-lookup-loading" message="Looking up record…" />
        </:loading>
        <:failed>
          <.error_state id="ets-lookup-error" message={@error_message} />
        </:failed>

        <p :if={chunk.records == []} id="ets-lookup-empty" class="text-base-content/70 text-sm">
          No record with this key. It may have been deleted.
        </p>

        <div
          :for={{record, index} <- Enum.with_index(chunk.records)}
          id={"ets-lookup-record-#{index}"}
          class="border-base-200 flex min-h-0 items-start gap-2 overflow-y-auto rounded-lg border p-3"
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

        <p :if={chunk.truncated?} id="ets-lookup-truncated" class="text-base-content/50 text-xs">
          Shortened to fit the term budget — raise it and refetch to see more.
        </p>
      </.async_result>
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
        "input input-sm input-bordered no-spinner font-mono w-24",
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

  defp truncated_record?(list) when is_list(list), do: Enum.any?(list, &truncated_record?/1)

  defp truncated_record?(map) when is_map(map) and not is_struct(map) do
    Enum.any?(map, fn {key, value} -> truncated_record?(key) or truncated_record?(value) end)
  end

  defp truncated_record?(_other), do: false

  defp preview(record) do
    record
    |> strip_markers()
    |> inspect(limit: 20, printable_limit: 128, width: :infinity)
  rescue
    _e -> inspect(record, limit: 20, printable_limit: 128, width: :infinity)
  end

  defp strip_markers(@truncated), do: :...

  defp strip_markers(list) when is_list(list), do: Enum.map(list, &strip_markers/1)

  defp strip_markers(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&strip_markers/1) |> List.to_tuple()
  end

  defp strip_markers(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {strip_markers(k), strip_markers(v)} end)
  end

  defp strip_markers(other), do: other
end
