defmodule VoyagerWeb.Components.DataTableComponents do
  @moduledoc """
  Reusable building blocks for the node inspection list pages.

  Two domain-agnostic pieces every list page can share: a sortable `table/1` and a `pager/1`.
  Both are stateless — the caller holds the sort and the page, and handles the `sort` and `paginate` events they emit.
  Page-specific fetch options belong with the page, not here.

  Columns are described as maps rather than slots so a page can keep its column
  list in one place and reuse it for both the header and the body:

      @columns [
        %{key: :pid, label: "PID", sortable?: false, align: :left},
        %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm}
      ]

  An optional `:width` (`:sm` or `:md`) fixes a column's width so its values
  cannot resize the table as they change; longer content truncates. Columns
  without one size to their content.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.Formatters

  @doc """
  The narrowest a page holding the table should get.
  """
  @spec page_min_width_class() :: String.t()
  def page_min_width_class, do: "min-w-6xl"

  @doc """
  Sortable table.

  `rows` is a list of `{dom_id, row}` tuples/
  Each column renders through the `:cell` slot, which receives
  `%{column: column, row: row, row_id: dom_id}`.
  """
  attr :id, :string, required: true
  attr :columns, :list, required: true
  attr :rows, :list, required: true, doc: "list of `{dom_id, row}` tuples"
  attr :sort_by, :atom, default: nil
  attr :direction, :atom, default: :desc
  attr :empty_message, :string, default: "No results."

  slot :cell, required: true

  def table(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 relative flex min-h-0 flex-1 flex-col border shadow-sm">
      <div class="bg-base-100 absolute h-2 w-full rounded-md"></div>
      <div class="min-h-0 flex-1 overflow-y-auto px-5 pb-5">
        <table id={@id} class="table-pin-rows table-md min-w-5xl table w-full table-fixed">
          <thead>
            <tr>
              <.column_header
                :for={column <- @columns}
                column={column}
                sort_by={@sort_by}
                direction={@direction}
              />
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []}>
              <td colspan={length(@columns)} class="text-base-content/70 py-8 text-center text-sm">
                {@empty_message}
              </td>
            </tr>
            <tr :for={{dom_id, row} <- @rows} id={dom_id}>
              <td
                :for={column <- @columns}
                data-column={column.key}
                class={["text-sm", align_class(column), width_class(column)]}
              >
                <div class="truncate">
                  {render_slot(@cell, %{column: column, row: row, row_id: dom_id})}
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :column, :map, required: true
  attr :sort_by, :atom, default: nil
  attr :direction, :atom, required: true

  defp column_header(%{column: %{sortable?: true}} = assigns) do
    assigns = assign(assigns, :active?, assigns.column.key == assigns.sort_by)

    ~H"""
    <th
      data-column={@column.key}
      class={["py-5", align_class(@column), width_class(@column)]}
      aria-sort={aria_sort(@active?, @direction)}
    >
      <button
        type="button"
        phx-click="sort"
        phx-value-key={@column.key}
        class={[
          "font-mono tracking-label flex w-full max-w-full cursor-pointer items-center gap-1 text-xs",
          "font-semibold uppercase transition-colors hover:text-base-content",
          justify_class(@column),
          @active? && "text-base-content",
          not @active? && "text-base-content/70"
        ]}
        aria-label={"Sort by #{@column.label}"}
      >
        <span class="truncate">{@column.label}</span>
        <span class="inline-flex shrink-0 items-center" aria-hidden="true">
          <.icon name="icon-move-up" class={["size-3.5", arrow_class(@active?, @direction, :asc)]} />
          <.icon
            name="icon-move-down"
            class={["size-3.5 -ml-0.5", arrow_class(@active?, @direction, :desc)]}
          />
        </span>
      </button>
    </th>
    """
  end

  defp column_header(assigns) do
    ~H"""
    <th
      data-column={@column.key}
      class={["bg-base-100 py-5", align_class(@column), width_class(@column)]}
    >
      <div class="font-mono tracking-label text-base-content/70 truncate text-xs font-semibold uppercase">
        {@column.label}
      </div>
    </th>
    """
  end

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
  attr :page_size_options, :list, default: [], doc: "adds a rows-per-page selector"

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

        <form
          :if={@page_size_options != []}
          id={"#{@id}-page-size-form"}
          phx-change="set_page_size"
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
          phx-click="paginate"
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
          phx-click="paginate"
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

  defp justify_class(%{align: :right}), do: "justify-end"
  defp justify_class(_column), do: "justify-start"

  defp align_class(%{align: :right}), do: "text-right"
  defp align_class(_column), do: "text-left"

  defp width_class(%{width: :sm}), do: "w-28 max-w-28"
  defp width_class(%{width: :md}), do: "w-36 max-w-36"
  defp width_class(_column), do: nil
end
