defmodule VoyagerWeb.Components.DataTableComponents do
  @moduledoc """
  Reusable building blocks for the node inspection list pages.

  These components are deliberately domain-agnostic so every list page
  (processes, ETS tables, ports, …) shares one table, toolbar and pager. They
  own no state: the caller supplies the rows and the current sort/page/limit,
  and receives events (`sort`, `paginate`, `set_limit`, `search`, `refresh`)
  which it is free to name via the `*_event` attributes.

  Columns are described as maps rather than slots so a page can keep its column
  list in one place and reuse it for both the header and the body:

      @columns [
        %{key: :pid, label: "PID", sortable?: false, align: :left},
        %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm}
      ]

  An optional `:width` (`:xs`, `:sm`, `:md`, `:lg`) fixes a column's width so
  its values cannot resize the table as they change; longer content truncates.
  Columns without one size to their content.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.Formatters

  @doc """
  Toolbar with a search box, a result-size selector, a timeout selector and a
  manual refresh button.

  Every control is optional: omit the matching attribute to leave it out.
  """
  attr :id, :string, required: true
  attr :search, :string, default: nil
  attr :search_placeholder, :string, default: "Search…"
  attr :search_event, :string, default: "search"
  attr :limit, :integer, default: nil, doc: "how many rows to fetch from the remote"
  attr :limit_options, :list, default: []
  attr :limit_event, :string, default: "set_limit"
  attr :limit_label, :string, default: "Fetch"
  attr :timeout, :integer, default: nil, doc: "request timeout in milliseconds"
  attr :timeout_min, :integer, default: 1_000
  attr :timeout_max, :integer, default: 30_000
  attr :timeout_event, :string, default: "set_timeout"
  attr :columns_options, :list, default: [], doc: "`{value, label, locked?}` triples"
  attr :columns_selected, :list, default: []
  attr :columns_event, :string, default: "set_columns"
  attr :loading?, :boolean, default: false

  def toolbar(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-end justify-between gap-3">
      <form
        :if={@search != nil}
        id={"#{@id}-search-form"}
        phx-change={@search_event}
        phx-submit={@search_event}
        class="grow"
      >
        <label class="input w-full max-w-md">
          <.icon name="icon-search" class="text-base-content/60 size-4" />
          <input
            id={"#{@id}-search"}
            type="search"
            name="search"
            value={@search}
            phx-debounce="300"
            placeholder={@search_placeholder}
            aria-label={@search_placeholder}
          />
        </label>
      </form>

      <div class="flex flex-wrap items-end gap-2">
        <%!-- The limit is a remote cost (rows copied off the node); page size
              only slices what was already fetched. --%>
        <.select_control
          :if={@limit != nil}
          id={"#{@id}-limit"}
          label={@limit_label}
          name="limit"
          event={@limit_event}
          value={to_string(@limit)}
          options={Enum.map(@limit_options, &{to_string(&1), to_string(&1)})}
        />

        <form
          :if={@timeout != nil}
          id={"#{@id}-timeout-form"}
          phx-change={@timeout_event}
          class="flex flex-col gap-1"
        >
          <label for={"#{@id}-timeout"} class="text-base-content/70 text-xs font-medium">
            Timeout (ms)
          </label>
          <%!-- A plain number input: the stepper's arrows are unhelpful at a
                millisecond granularity. --%>
          <input
            id={"#{@id}-timeout"}
            type="number"
            name="timeout"
            value={@timeout}
            min={@timeout_min}
            max={@timeout_max}
            step="100"
            inputmode="numeric"
            phx-debounce="500"
            aria-label="Request timeout in milliseconds"
            class="input input-sm input-bordered no-spinner font-mono w-24"
          />
        </form>

        <form
          :if={@columns_options != []}
          id={"#{@id}-columns-form"}
          phx-change={@columns_event}
          class="flex flex-col gap-1"
        >
          <span class="text-base-content/70 text-xs font-medium">Columns</span>
          <.multiselect
            id={"#{@id}-columns"}
            name="columns"
            label="Columns"
            options={@columns_options}
            selected={@columns_selected}
          />
        </form>
      </div>
    </div>
    """
  end

  @doc """
  Labelled `<select>` that pushes `event` with the given `name` on change.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true, doc: "list of `{label, value}` tuples"

  def select_control(assigns) do
    ~H"""
    <form id={"#{@id}-form"} phx-change={@event} class="flex flex-col gap-1">
      <label for={@id} class="text-base-content/70 text-xs font-medium">{@label}</label>
      <select id={@id} name={@name} class="select select-sm w-24">
        <option :for={{label, value} <- @options} value={value} selected={value == @value}>
          {label}
        </option>
      </select>
    </form>
    """
  end

  @doc """
  Sortable table.

  `rows` is a list of `{dom_id, row}` tuples so the caller can drive it from a
  LiveView stream or a plain list. Each column renders through the `:cell` slot,
  which receives `%{column: column, row: row}`.
  """
  attr :id, :string, required: true
  attr :columns, :list, required: true
  attr :rows, :list, required: true, doc: "list of `{dom_id, row}` tuples"
  attr :sort_by, :atom, default: nil
  attr :direction, :atom, default: :desc
  attr :sort_event, :string, default: "sort"
  attr :row_click_event, :string, default: nil
  attr :row_id_key, :atom, default: :id, doc: "row key holding the value sent on row click"
  attr :selected_id, :string, default: nil
  attr :empty_message, :string, default: "No results."

  attr :resizable?, :boolean,
    default: false,
    doc: "adds a drag handle to each header; widths persist per table id"

  slot :cell, required: true

  def table(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <%!-- No horizontal scroll: the columns are percentages of the table and
            resizing trades width between neighbours, so the total always fits
            and overflowing content truncates instead. --%>
      <div class="p-5">
        <%!-- DaisyUI `table`, sized to match the node-info tables: `table-md`
              for their row height and `table-fixed` so the column widths
              actually hold. --%>
        <table
          id={@id}
          phx-hook={@resizable? && "TableColumnResize"}
          class="table-pin-rows table-md table w-full table-fixed"
        >
          <thead>
            <tr>
              <%!-- The last column has nothing to its right to give or take
                    space from, so it gets no handle. --%>
              <.column_header
                :for={{column, index} <- Enum.with_index(@columns)}
                column={column}
                sort_by={@sort_by}
                direction={@direction}
                sort_event={@sort_event}
                resizable?={@resizable? and index < length(@columns) - 1}
              />
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []}>
              <td colspan={length(@columns)} class="text-base-content/70 py-8 text-center text-sm">
                {@empty_message}
              </td>
            </tr>
            <tr
              :for={{dom_id, row} <- @rows}
              id={dom_id}
              phx-click={@row_click_event}
              phx-value-id={row_id(row, @row_id_key)}
              class={[
                @row_click_event && "cursor-pointer transition-colors hover:bg-primary/15",
                @selected_id && @selected_id == row_id(row, @row_id_key) && "bg-primary/20"
              ]}
            >
              <%!-- `truncate` needs a block-level box to clamp against, so the
                    cell content is wrapped rather than truncated on the td. --%>
              <td
                :for={column <- @columns}
                data-column={column.key}
                class={["text-sm", align_class(column), width_class(column)]}
              >
                <div class="truncate">
                  {render_slot(@cell, %{column: column, row: row})}
                </div>
              </td>
            </tr>
            <%!-- Blank filler rows keep the table the same height when a fetch
                  returns fewer rows, so the page does not jump. --%>
            <%!-- An empty line box is a fraction shorter than one holding text,
                  so the filler's inner height is pinned to match a real row
                  exactly and the table height cannot drift. --%>
            <%!-- An empty cell's line box is a fraction shorter than one
                  holding glyphs, so the row height is pinned directly (h-10 =
                  the 2.5rem a populated row settles at) rather than being left
                  to the text metrics. --%>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :column, :map, required: true
  attr :sort_by, :atom, default: nil
  attr :direction, :atom, required: true
  attr :sort_event, :string, required: true
  attr :resizable?, :boolean, default: false

  defp column_header(%{column: %{sortable?: true}} = assigns) do
    assigns = assign(assigns, :active?, assigns.column.key == assigns.sort_by)

    ~H"""
    <th
      data-column={@column.key}
      class={["relative", align_class(@column), width_class(@column)]}
      aria-sort={aria_sort(@active?, @direction)}
    >
      <button
        type="button"
        phx-click={@sort_event}
        phx-value-key={@column.key}
        class={[
          "font-mono tracking-label flex w-full max-w-full items-center gap-1 text-xs",
          "font-semibold uppercase transition-colors hover:text-base-content",
          justify_class(@column),
          @active? && "text-base-content",
          not @active? && "text-base-content/70"
        ]}
        aria-label={"Sort by #{@column.label}"}
      >
        <span class="truncate">{@column.label}</span>
        <%!-- Both directions are always shown so a sortable column is
              recognisable at a glance; the active one is undimmed. --%>
        <span class="inline-flex shrink-0 items-center" aria-hidden="true">
          <.icon name="icon-move-up" class={["size-3", arrow_class(@active?, @direction, :asc)]} />
          <.icon
            name="icon-move-down"
            class={["size-3 -ml-0.5", arrow_class(@active?, @direction, :desc)]}
          />
        </span>
      </button>
      <.resize_handle :if={@resizable?} label={@column.label} />
    </th>
    """
  end

  defp column_header(assigns) do
    ~H"""
    <th
      data-column={@column.key}
      class={["relative", align_class(@column), width_class(@column)]}
    >
      <div class="font-mono tracking-label text-base-content/70 truncate text-xs font-semibold uppercase">
        {@column.label}
      </div>
      <.resize_handle :if={@resizable?} label={@column.label} />
    </th>
    """
  end

  # Only the arrow matching the active sort direction is undimmed; every other
  # arrow stays grayed so it reads as "sortable" rather than "sorted".
  defp arrow_class(true, direction, direction), do: "text-primary"
  defp arrow_class(_active?, _direction, _arrow), do: "text-base-content/30"

  defp aria_sort(true, :asc), do: "ascending"
  defp aria_sort(true, :desc), do: "descending"
  defp aria_sort(_active?, _direction), do: "none"

  attr :label, :string, required: true

  defp resize_handle(assigns) do
    ~H"""
    <span
      data-resize-handle
      role="separator"
      aria-orientation="vertical"
      aria-label={"Resize #{@label} column"}
      class="group absolute inset-y-0 -right-1 z-20 flex w-2 cursor-col-resize touch-none items-center justify-center"
    >
      <span class="bg-base-content/20 h-1/2 w-px transition-colors group-hover:bg-primary" />
    </span>
    """
  end

  @doc """
  Pager for a client-side page over an already-fetched result set.

  `total` is the number of rows held locally; `page` is 1-based.
  """
  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :total, :integer, required: true
  attr :event, :string, default: "paginate"
  attr :page_size_options, :list, default: [], doc: "adds a rows-per-page selector"
  attr :page_size_event, :string, default: "set_page_size"

  def pager(assigns) do
    total_pages = max(div(assigns.total + assigns.page_size - 1, assigns.page_size), 1)
    first = if assigns.total == 0, do: 0, else: (assigns.page - 1) * assigns.page_size + 1
    last = min(assigns.page * assigns.page_size, assigns.total)

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:first, first)
      |> assign(:last, last)

    ~H"""
    <div id={@id} class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-3">
        <p class="text-base-content/70 text-xs">
          Showing
          <span class="font-mono">{Formatters.format_integer(@first)}–{Formatters.format_integer(
            @last
          )}</span>
          of <span class="font-mono">{Formatters.format_integer(@total)}</span>
        </p>

        <%!-- Rows per page belongs with the paging controls: it only reslices
              what was already fetched. --%>
        <form
          :if={@page_size_options != []}
          id={"#{@id}-page-size-form"}
          phx-change={@page_size_event}
          class="flex items-center gap-2"
        >
          <label for={"#{@id}-page-size"} class="text-base-content/70 text-xs">Per page</label>
          <select
            id={"#{@id}-page-size"}
            name="page_size"
            class="select select-sm w-20"
          >
            <option
              :for={size <- @page_size_options}
              value={to_string(size)}
              selected={size == @page_size}
            >
              {size}
            </option>
          </select>
        </form>
      </div>

      <div :if={@total_pages > 1} class="join">
        <button
          type="button"
          id={"#{@id}-prev"}
          phx-click={@event}
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          class="join-item btn btn-sm"
          aria-label="Previous page"
        >
          <.icon name="icon-chevron-right" class="size-4 rotate-180" />
        </button>
        <span class="join-item btn btn-sm btn-ghost font-mono pointer-events-none">
          {@page} / {@total_pages}
        </span>
        <button
          type="button"
          id={"#{@id}-next"}
          phx-click={@event}
          phx-value-page={@page + 1}
          disabled={@page >= @total_pages}
          class="join-item btn btn-sm"
          aria-label="Next page"
        >
          <.icon name="icon-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Caption describing the scan behind the current result set: how many rows the
  scan found and how many of them were returned.

  Ranking runs over the scanned population, so a truncated scan is surfaced
  explicitly rather than implying the list is exhaustive. Truncation is normal
  whenever the limit is smaller than the population, so it reads as info.
  """
  attr :id, :string, required: true
  attr :shown, :integer, required: true, doc: "rows returned by the remote"
  attr :scanned, :integer, required: true, doc: "rows found during the scan"
  attr :truncated?, :boolean, default: false

  def scan_summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
      <span>
        Found <span class="font-mono text-base-content">{Formatters.format_integer(@scanned)}</span>
        processes, returned
        <span class="font-mono text-base-content">{Formatters.format_integer(@shown)}</span>
      </span>
      <span :if={@truncated?} class="badge badge-info badge-soft badge-xs">truncated</span>
    </div>
    """
  end

  @doc """
  Dismissable explanation of how a page's data is fetched and paged.
  """
  attr :id, :string, required: true
  slot :inner_block, required: true

  def info_note(assigns) do
    ~H"""
    <div id={@id} role="note" class="alert alert-info py-3 text-sm">
      <.icon name="icon-info" class="size-5 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  # Row ids double as `phx-value-id`, so they must survive values that have no
  # `String.Chars` implementation (a pid identifying a process row, say).
  defp row_id(row, key), do: row |> Map.get(key) |> to_dom_value()

  defp to_dom_value(value) when is_binary(value), do: value
  defp to_dom_value(value) when is_pid(value), do: value |> :erlang.pid_to_list() |> to_string()
  defp to_dom_value(value) when is_port(value), do: value |> :erlang.port_to_list() |> to_string()
  defp to_dom_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_dom_value(value), do: inspect(value)

  defp justify_class(%{align: :right}), do: "justify-end"
  defp justify_class(%{align: :center}), do: "justify-center"
  defp justify_class(_column), do: "justify-start"

  defp align_class(%{align: :right}), do: "text-right"
  defp align_class(%{align: :center}), do: "text-center"
  defp align_class(_column), do: "text-left"

  # A column may declare a fixed width so its values cannot widen the table as
  # they change; anything longer truncates. Named sizes rather than an
  # interpolated value, since Tailwind only emits classes it can see literally.
  # `w-*` on a table cell is a minimum unless the table is fixed-layout, so the
  # matching `max-w-*` is what actually forces truncation.
  defp width_class(%{width: :xs}), do: "w-20 max-w-20"
  defp width_class(%{width: :sm}), do: "w-28 max-w-28"
  defp width_class(%{width: :md}), do: "w-36 max-w-36"
  defp width_class(%{width: :lg}), do: "w-48 max-w-48"
  defp width_class(_column), do: nil
end
