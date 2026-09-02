defmodule VoyagerWeb.Components.EtsTableComponents do
  @moduledoc """
  ETS-specific presentation for the table list and details pages: the
  controls form, the column definitions with their cell formatting, the side
  panel for the selected table and the full metadata sections.
  """

  use VoyagerWeb, :component

  import VoyagerWeb.Components.DetailsPanelComponents,
    only: [
      close_button: 1,
      copyable: 1,
      kv: 1,
      kv_skeleton: 1,
      resize_handle: 1,
      section: 1,
      show_more_button: 1
    ]

  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsTableListControls

  # Ordered as they appear in the table; the last column only holds the link
  # to the details page.
  @columns [
    %{key: :name, label: "Table", sortable?: true, align: :left},
    %{key: :protection, label: "Protection", sortable?: false, align: :left, width: :md},
    %{key: :type, label: "Type", sortable?: false, align: :left, width: :md},
    %{key: :size, label: "Objects", sortable?: true, align: :right, width: :md},
    %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm},
    %{key: :owner, label: "Owner", sortable?: true, align: :left, width: :md},
    %{key: :named_table, label: "Named", sortable?: false, align: :left, width: :sm},
    %{key: :keypos, label: "Keypos", sortable?: false, align: :right, width: :sm},
    %{key: :heir, label: "Heir", sortable?: false, align: :left, width: :md},
    %{key: :compressed, label: "Compressed", sortable?: false, align: :left, width: :sm},
    %{key: :read_concurrency, label: "Read conc.", sortable?: false, align: :left, width: :sm},
    %{key: :write_concurrency, label: "Write conc.", sortable?: false, align: :left, width: :sm},
    %{
      key: :decentralized_counters,
      label: "Dec. counters",
      sortable?: false,
      align: :left,
      width: :sm
    },
    %{key: :details, label: "", sortable?: false, align: :right, width: :xs}
  ]

  @doc """
  Column definitions for the selected attributes, in display order. The
  details column is always there: it is a link, not data to pick.
  """
  @spec columns([atom()]) :: [map()]
  def columns(selected) do
    Enum.filter(@columns, &(&1.key == :details or &1.key in selected))
  end

  @doc "The table's name as shown everywhere, e.g. `:my_table` or `MyApp.Cache`."
  @spec display_name(map()) :: String.t()
  def display_name(%{name: name}), do: inspect(name)

  @doc "Human label for a selectable column."
  @spec column_label(atom()) :: String.t()
  def column_label(key) do
    Enum.find(@columns, &(&1.key == key)).label
  end

  @doc """
  The controls form: the client-side search, the request timeout and the
  column picker.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def controls(assigns) do
    {min_timeout, max_timeout} = EtsTableListControls.timeout_bounds()

    assigns =
      assigns
      |> assign(:min_timeout, min_timeout)
      |> assign(:max_timeout, max_timeout)
      |> assign(:column_options, EtsTableListControls.column_options(&column_label/1))

    ~H"""
    <.form for={@form} id="ets-table-controls" phx-change="validate" class="flex flex-col gap-1">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <label class="input mt-5 w-full max-w-md">
          <.icon name="icon-search" class="text-base-content/60 size-4" />
          <input
            id={@form[:search].id}
            type="search"
            name={@form[:search].name}
            value={@form[:search].value}
            phx-debounce="300"
            placeholder="Filter by name, id, type or owner"
            aria-label="Filter by name, id, type or owner"
          />
        </label>

        <div class="grid-cols-[auto_auto] grid-rows-[auto_auto_auto] grid items-center gap-x-2">
          <.field_label field={@form[:timeout]} label="Timeout (ms)" />
          <span class="text-base-content/70 text-xs font-medium">Columns</span>

          <input
            id={@form[:timeout].id}
            type="number"
            name={@form[:timeout].name}
            value={@form[:timeout].value}
            min={@min_timeout}
            max={@max_timeout}
            step="100"
            inputmode="numeric"
            phx-debounce="500"
            class={[
              "input input-sm input-bordered no-spinner font-mono w-24",
              @form[:timeout].errors != [] && "input-error"
            ]}
          />

          <.multiselect
            id="ets-table-controls-columns"
            name={@form[:columns].name}
            label="Columns"
            options={@column_options}
            selected={List.wrap(@form[:columns].value)}
          />

          <.field_error field={@form[:timeout]} />
        </div>
      </div>
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true

  defp field_label(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <label for={@field.id} class="text-base-content/70 text-xs font-medium">{@label}</label>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_error(assigns) do
    ~H"""
    <p class="font-mono text-error relative h-4 w-24 text-xs">
      <span class="absolute left-0 whitespace-nowrap">
        {@field.errors |> Enum.map_join(", ", &translate_error/1)}
      </span>
    </p>
    """
  end

  @doc """
  Caption describing the fetch behind the current rows.
  """
  attr :id, :string, required: true
  attr :shown, :integer, required: true, doc: "rows left after the search"
  attr :total, :integer, required: true, doc: "tables the node reported"
  attr :total_memory, :integer, required: true, doc: "bytes held by every table together"
  attr :round_trip_ms, :integer, default: nil, doc: "round trip of the fetch that produced these"

  def summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 text-xs">
      <%= if @shown == @total do %>
        Fetched <span class="font-mono text-base-content">{Formatters.format_integer(@total)}</span>
        {pluralize(@total, "table")}
      <% else %>
        Showing <span class="font-mono text-base-content">{Formatters.format_integer(@shown)}</span>
        of <span class="font-mono text-base-content">{Formatters.format_integer(@total)}</span>
        {pluralize(@total, "table")} fetched
      <% end %>
      <DataTableComponents.round_trip :if={@round_trip_ms} ms={@round_trip_ms} /> ·
      <span class="font-mono text-base-content">{Formatters.format_bytes(@total_memory)}</span>
      in total
    </div>
    """
  end

  @doc """
  Renders a single cell of the ETS table list.
  """
  attr :column, :map, required: true
  attr :row, :map, required: true
  attr :row_id, :string, required: true, doc: "stable prefix for this row's element ids"
  attr :table_href, :string, required: true, doc: "opens this row's table in the side panel"
  attr :details_href, :string, required: true, doc: "details page for this row's table"
  attr :owner_href, :string, required: true, doc: "details page for the owning process"

  def cell(assigns) do
    ~H"""
    <%= case @column.key do %>
      <% :name -> %>
        <.name_cell table={@row} row_id={@row_id} href={@table_href} />
      <% :protection -> %>
        <.protection_cell protection={@row.protection} row_id={@row_id} />
      <% :type -> %>
        <DataTableComponents.value_cell
          id={"#{@row_id}-type"}
          value={Atom.to_string(@row.type)}
          muted
        />
      <% :size -> %>
        <DataTableComponents.value_cell
          id={"#{@row_id}-size"}
          value={Formatters.format_integer(@row.size)}
        />
      <% :memory -> %>
        <DataTableComponents.value_cell
          id={"#{@row_id}-memory"}
          value={Formatters.format_bytes(@row.memory)}
          tip={format_exact_bytes(@row.memory)}
        />
      <% :owner -> %>
        <ProcessComponents.pid_cell pid={@row.owner} row_id={@row_id} href={@owner_href} />
      <% :keypos -> %>
        <DataTableComponents.value_cell
          id={"#{@row_id}-keypos"}
          value={Integer.to_string(@row.keypos)}
        />
      <% :heir -> %>
        <DataTableComponents.value_cell id={"#{@row_id}-heir"} value={format_heir(@row.heir)} muted />
      <% :details -> %>
        <.link
          id={"#{@row_id}-details"}
          navigate={@details_href}
          title="Open table details"
          aria-label="Open table details"
          class="btn btn-ghost btn-square toolbar-btn-sm text-base-content/60 hover:text-primary"
        >
          <.icon name="icon-arrow-right" class="toolbar-icon-sm" />
        </.link>
      <% key -> %>
        <DataTableComponents.value_cell id={"#{@row_id}-#{key}"} value={flag(@row, key)} muted />
    <% end %>
    """
  end

  # The on/off table options; `decentralized_counters` is only reported by
  # nodes that know it.
  defp flag(row, key) do
    case Map.get(row, key) do
      nil -> DataTableComponents.placeholder()
      :auto -> "auto"
      value when is_boolean(value) -> yes_no(value)
    end
  end

  attr :table, :map, required: true
  attr :row_id, :string, required: true
  attr :href, :string, required: true

  defp name_cell(assigns) do
    assigns =
      assigns
      |> assign(:name, display_name(assigns.table))
      |> assign(:id, TableId.display(assigns.table.id))

    ~H"""
    <.tooltip
      id={"#{@row_id}-name-tip"}
      interactive
      class="min-w-0 max-w-full"
      tip_class="font-mono"
    >
      <%!-- Only the name opens the panel, so it carries the affordances of a link. --%>
      <.link
        patch={@href}
        class="font-mono text-primary flex min-w-0 max-w-full items-baseline gap-2 text-sm hover:underline focus-visible:underline"
      >
        <span class="truncate">{@name}</span>
        <%!-- An unnamed table is only reachable by its reference, so it is
              shown beside the name it was created with. --%>
        <span :if={not @table.named_table} class="text-base-content/60 truncate text-xs">
          {@id}
        </span>
      </.link>
      <:content>
        <div class="flex items-center gap-1">
          <span id={"#{@row_id}-name-copy-text"}>{@id}</span>
          <.copy_button
            id={"#{@row_id}-name-copy"}
            target={"##{@row_id}-name-copy-text"}
            label="Copy table id"
            icon_only
            size={:sm}
            class="text-base-content/60 shrink-0 hover:text-primary"
          />
        </div>
      </:content>
    </.tooltip>
    """
  end

  attr :protection, :atom, required: true
  attr :row_id, :string, required: true

  defp protection_cell(%{protection: :private} = assigns) do
    ~H"""
    <.private_badge id={"#{@row_id}-protection"} size={:sm} />
    """
  end

  defp protection_cell(assigns) do
    ~H"""
    <span
      id={"#{@row_id}-protection"}
      class="font-mono text-base-content/70 block truncate text-sm"
    >
      {@protection}
    </span>
    """
  end

  @doc """
  Marks a private table, which only its owner process can read.
  """
  attr :id, :string, required: true
  attr :size, :atom, required: true, values: [:xs, :sm]

  def private_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "badge badge-warning badge-soft font-mono",
        if(@size == :xs, do: "badge-xs", else: "badge-sm")
      ]}
      title="Only the owner process can read this table"
    >
      private
    </span>
    """
  end

  @doc """
  Side panel with the basics of the selected table and a way to its details
  page.

  Open whenever a `?table=` param is present. What it shows depends on how far
  resolving that param got: the table once a fetch found it, a skeleton while
  the first fetch is still out, a notice when the node could not be fetched,
  or a not-found notice when the last fetch had no such table.
  """
  attr :id, :string, required: true
  attr :table_param, :string, default: nil, doc: "the `?table=` value; closed when nil"
  attr :table, :map, default: nil, doc: "the resolved table, when the last fetch had it"

  attr :fetch_status, :atom,
    required: true,
    values: [:pending, :fetched, :failed],
    doc: "whether a fetch has landed, so an unresolved param can be explained"

  attr :owner_href, :string, default: nil, doc: "details page for the owning process"
  attr :details_href, :string, default: nil, doc: "details page for the table"

  def details_panel(assigns) do
    assigns = assign(assigns, :open?, assigns.table_param != nil)

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
      <%= if @open? do %>
        <.panel_header
          id={@id}
          title={if @table, do: display_name(@table), else: @table_param}
          table={@table}
        />
        <%= cond do %>
          <% @table -> %>
            <.panel_body
              id={@id}
              table={@table}
              owner_href={@owner_href}
              details_href={@details_href}
            />
          <% @fetch_status == :pending -> %>
            <.panel_skeleton />
          <% @fetch_status == :failed -> %>
            <.panel_notice id={"#{@id}-unavailable"}>
              The tables could not be fetched, so this one cannot be shown yet.
            </.panel_notice>
          <% true -> %>
            <.panel_notice id={"#{@id}-not-found"}>
              No table named <span class="font-mono">{@table_param}</span>
              was found in the last fetch. It may have been deleted, or an unnamed
              table may have been recreated under a new reference.
            </.panel_notice>
        <% end %>
      <% end %>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :table, :map, default: nil

  defp panel_header(assigns) do
    ~H"""
    <div class="border-base-200 flex items-start gap-3 border-b px-5 py-4">
      <div class="flex min-w-0 flex-1 flex-col gap-1.5">
        <div class="flex items-center gap-2">
          <.icon name="icon-database-search" class="text-primary size-3.5" />
          <div class="font-mono text-base-content text-xs uppercase">ETS table</div>
          <.private_badge
            :if={@table && @table.protection == :private}
            id={"#{@id}-private-badge"}
            size={:xs}
          />
        </div>
        <div class="flex min-w-0 flex-col gap-0.5">
          <.copyable
            id={"#{@id}-name"}
            class="font-mono text-base-content break-all text-sm font-medium"
            text={@title}
            label="Copy table name"
          />
          <.copyable
            :if={@table && not @table.named_table}
            id={"#{@id}-table-id"}
            class="font-mono text-base-content/70 text-xs"
            text={TableId.display(@table.id)}
            label="Copy table id"
          />
        </div>
      </div>
      <.close_button panel_id={@id} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :table, :map, required: true
  attr :owner_href, :string, required: true
  attr :details_href, :string, required: true

  defp panel_body(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4">
      <.section title="Overview">
        <.kv label="Type" value={Atom.to_string(@table.type)} />
        <.kv label="Protection" value={Atom.to_string(@table.protection)} />
        <.kv label="Objects" value={Formatters.format_integer(@table.size)} />
        <.kv label="Memory" value={format_memory(@table.memory)} />
        <.owner_kv href={@owner_href} pid={@table.owner} last />
      </.section>
    </div>
    <.show_more_button panel_id={@id} navigate={@details_href} />
    """
  end

  @doc """
  Every piece of metadata the list API reports for one table, for the details
  page.
  """
  attr :id, :string, required: true
  attr :table, :map, required: true
  attr :owner_href, :string, required: true, doc: "details page for the owning process"

  def details(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4 lg:grid-cols-2">
      <.details_card>
        <.section title="Overview">
          <.kv label="Type" value={Atom.to_string(@table.type)} />
          <.kv label="Protection" value={Atom.to_string(@table.protection)} />
          <.kv label="Named table" value={flag(@table, :named_table)} />
          <.kv label="Key position" value={Integer.to_string(@table.keypos)} />
          <.owner_kv href={@owner_href} pid={@table.owner} />
          <.kv label="Heir" value={format_heir(@table.heir)} last />
        </.section>
      </.details_card>

      <.details_card>
        <.section title="Storage">
          <.kv label="Objects" value={Formatters.format_integer(@table.size)} />
          <.kv label="Memory" value={format_memory(@table.memory)} />
          <.kv label="Compressed" value={flag(@table, :compressed)} />
          <.kv label="Read concurrency" value={flag(@table, :read_concurrency)} />
          <.kv label="Write concurrency" value={flag(@table, :write_concurrency)} />
          <.kv label="Decentralized counters" value={flag(@table, :decentralized_counters)} last />
        </.section>
      </.details_card>

      <.details_card class="lg:col-span-2">
        <.section title="Records">
          <.peek_button id={"#{@id}-peek"} private?={@table.protection == :private} />
        </.section>
      </.details_card>
    </div>
    """
  end

  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp details_card(assigns) do
    ~H"""
    <div class={["card bg-base-100 border-base-200 border shadow-sm", @class]}>
      <div class="card-body p-5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :pid, :any, required: true
  attr :last, :boolean, default: false

  defp owner_kv(assigns) do
    ~H"""
    <.kv label="Owner" last={@last}>
      <.link navigate={@href} class="text-primary hover:underline">
        {Formatters.format_pid(@pid)}
      </.link>
    </.kv>
    """
  end

  attr :id, :string, required: true
  attr :private?, :boolean, required: true

  # Reading records is not built yet. The control is already here so a private
  # table can say now why it will never be readable from outside its owner.
  defp peek_button(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <button
        type="button"
        id={@id}
        disabled
        aria-describedby={"#{@id}-note"}
        class="btn btn-sm w-max gap-2"
      >
        <.icon name="icon-eye" class="size-4" /> Peek records
        <span :if={not @private?} class="badge badge-primary badge-soft badge-xs">Soon</span>
      </button>
      <p id={"#{@id}-note"} class="text-base-content/70 text-xs">
        <%= if @private? do %>
          Private tables can only be read by their owner process.
        <% else %>
          Reading records is on its way.
        <% end %>
      </p>
    </div>
    """
  end

  defp panel_skeleton(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4">
      <.section title="Overview">
        <.kv_skeleton label="Type" narrow />
        <.kv_skeleton label="Protection" narrow />
        <.kv_skeleton label="Objects" narrow />
        <.kv_skeleton label="Memory" />
        <.kv_skeleton label="Owner" last />
      </.section>
    </div>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  defp panel_notice(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-y-auto px-5 py-4">
      <div id={@id} role="status" class="alert alert-warning text-xs">
        <.icon name="icon-circle-alert" class="size-4 shrink-0" />
        <span>{render_slot(@inner_block)}</span>
      </div>
    </div>
    """
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp format_heir(:none), do: "none"
  defp format_heir(pid) when is_pid(pid), do: Formatters.format_pid(pid)

  defp format_memory(bytes),
    do: "#{Formatters.format_bytes(bytes)} (#{format_exact_bytes(bytes)})"

  defp format_exact_bytes(bytes), do: "#{Formatters.format_integer(bytes)} B"
end
