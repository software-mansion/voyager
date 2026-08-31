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
  attr :limit_min, :integer, default: 1
  attr :limit_max, :integer, default: 1_000
  attr :limit_event, :string, default: "set_limit"
  attr :limit_label, :string, default: "Fetch"
  attr :page_size, :integer, default: nil, doc: "how many fetched rows to show per page"
  attr :page_size_options, :list, default: []
  attr :page_size_event, :string, default: "set_page_size"
  attr :timeout, :integer, default: nil, doc: "request timeout in whole seconds"
  attr :timeout_min, :integer, default: 1
  attr :timeout_max, :integer, default: 30
  attr :timeout_event, :string, default: "set_timeout"
  attr :refresh_event, :string, default: "refresh"
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
        <label class="input input-sm w-full max-w-xs">
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
        <%!-- The limit is a remote cost (rows copied off the node), so it is a
              free integer up to a ceiling; page size only slices what was
              already fetched, so it stays a small discrete choice. --%>
        <form
          :if={@limit != nil}
          id={"#{@id}-limit-form"}
          phx-change={@limit_event}
          class="flex flex-col gap-1"
        >
          <label for={"#{@id}-limit"} class="text-base-content/70 text-xs font-medium">
            {@limit_label}
          </label>
          <.input
            id={"#{@id}-limit"}
            type="number-stepper"
            name="limit"
            value={@limit}
            min={@limit_min}
            max={@limit_max}
            step="1"
            phx-debounce="500"
            aria-label="Number of processes to fetch"
          />
        </form>

        <.select_control
          :if={@page_size != nil}
          id={"#{@id}-page-size"}
          label="Per page"
          name="page_size"
          event={@page_size_event}
          value={to_string(@page_size)}
          options={Enum.map(@page_size_options, &{to_string(&1), to_string(&1)})}
        />

        <form
          :if={@timeout != nil}
          id={"#{@id}-timeout-form"}
          phx-change={@timeout_event}
          class="flex flex-col gap-1"
        >
          <label for={"#{@id}-timeout"} class="text-base-content/70 text-xs font-medium">
            Timeout (s)
          </label>
          <.input
            id={"#{@id}-timeout"}
            type="number-stepper"
            name="timeout"
            value={@timeout}
            min={@timeout_min}
            max={@timeout_max}
            step="1"
            phx-debounce="500"
            aria-label="Request timeout in seconds"
          />
        </form>

        <.tooltip id={"#{@id}-refresh-tip"} position="bottom">
          <button
            type="button"
            id={"#{@id}-refresh"}
            phx-click={@refresh_event}
            phx-throttle="1000"
            aria-label="Refresh"
            class="btn btn-ghost btn-square toolbar-btn"
          >
            <.icon
              name="icon-rotate-cw"
              class={["toolbar-icon", @loading? && "motion-safe:animate-spin"]}
            />
          </button>
          <:content>Refresh</:content>
        </.tooltip>
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

  slot :cell, required: true

  def table(assigns) do
    ~H"""
    <div class="border-base-300 bg-base-100 overflow-x-auto rounded-lg border">
      <table id={@id} class="table-zebra table-pin-rows table">
        <thead>
          <tr>
            <.column_header
              :for={column <- @columns}
              column={column}
              sort_by={@sort_by}
              direction={@direction}
              sort_event={@sort_event}
            />
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan={length(@columns)} class="text-base-content/70 py-8 text-center">
              {@empty_message}
            </td>
          </tr>
          <%!-- The zebra stripe already tints alternate rows, so a plain
                `hover:bg-base-200` is invisible on half the table; hover uses
                the primary tint (and `!` to win over the stripe) instead. --%>
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            phx-click={@row_click_event}
            phx-value-id={row_id(row, @row_id_key)}
            class={[
              @row_click_event && "cursor-pointer transition-colors hover:!bg-primary/25",
              @selected_id && @selected_id == row_id(row, @row_id_key) && "!bg-primary/30"
            ]}
          >
            <%!-- `truncate` needs a block-level box to clamp against, so the
                  cell content is wrapped rather than truncated on the td. --%>
            <td
              :for={column <- @columns}
              class={["py-3", align_class(column), width_class(column)]}
            >
              <div class="truncate">
                {render_slot(@cell, %{column: column, row: row})}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :column, :map, required: true
  attr :sort_by, :atom, default: nil
  attr :direction, :atom, required: true
  attr :sort_event, :string, required: true

  defp column_header(%{column: %{sortable?: true}} = assigns) do
    assigns = assign(assigns, :active?, assigns.column.key == assigns.sort_by)

    ~H"""
    <th
      class={[align_class(@column), width_class(@column)]}
      aria-sort={aria_sort(@active?, @direction)}
    >
      <button
        type="button"
        phx-click={@sort_event}
        phx-value-key={@column.key}
        class={[
          "inline-flex items-center gap-1 transition-colors hover:text-base-content",
          @active? && "text-base-content",
          not @active? && "text-base-content/70"
        ]}
        aria-label={"Sort by #{@column.label}"}
      >
        {@column.label}
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
    </th>
    """
  end

  defp column_header(assigns) do
    ~H"""
    <th class={["text-base-content/70", align_class(@column), width_class(@column)]}>
      <div class="truncate">{@column.label}</div>
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

  @doc """
  Pager for a client-side page over an already-fetched result set.

  `total` is the number of rows held locally; `page` is 1-based.
  """
  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :total, :integer, required: true
  attr :event, :string, default: "paginate"

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
      <p class="text-base-content/70 text-xs">
        Showing
        <span class="font-mono">{Formatters.format_integer(@first)}–{Formatters.format_integer(@last)}</span>
        of <span class="font-mono">{Formatters.format_integer(@total)}</span>
      </p>

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
  attr :last_updated, :any, default: nil

  def scan_summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
      <span>
        Found <span class="font-mono text-base-content">{Formatters.format_integer(@scanned)}</span>
        processes, returned
        <span class="font-mono text-base-content">{Formatters.format_integer(@shown)}</span>
      </span>
      <span :if={@truncated?} class="badge badge-info badge-soft badge-xs">truncated</span>
      <span :if={@last_updated} class="text-base-content/60">
        · updated {Formatters.format_time(@last_updated)}
      </span>
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
    <div id={@id} role="note" class="alert alert-info py-2.5 text-xs">
      <.icon name="icon-info" class="size-4 shrink-0" />
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
