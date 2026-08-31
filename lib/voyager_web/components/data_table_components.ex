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
        %{key: :memory, label: "Memory", sortable?: true, align: :right}
      ]
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
  attr :limit, :integer, default: nil
  attr :limit_options, :list, default: []
  attr :limit_event, :string, default: "set_limit"
  attr :limit_label, :string, default: "Rows"
  attr :timeout, :integer, default: nil
  attr :timeout_options, :list, default: []
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
        <.select_control
          :if={@limit != nil}
          id={"#{@id}-limit"}
          label={@limit_label}
          name="limit"
          event={@limit_event}
          value={to_string(@limit)}
          options={Enum.map(@limit_options, &{to_string(&1), to_string(&1)})}
        />

        <.select_control
          :if={@timeout != nil}
          id={"#{@id}-timeout"}
          label="Timeout"
          name="timeout"
          event={@timeout_event}
          value={to_string(@timeout)}
          options={@timeout_options}
        />

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
      <table id={@id} class="table-zebra table-pin-rows table table-sm">
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
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            phx-click={@row_click_event}
            phx-value-id={row_id(row, @row_id_key)}
            class={[
              @row_click_event && "hover:bg-base-200 cursor-pointer transition-colors",
              @selected_id && @selected_id == row_id(row, @row_id_key) && "bg-base-200"
            ]}
          >
            <td
              :for={column <- @columns}
              class={["whitespace-nowrap", align_class(column)]}
            >
              {render_slot(@cell, %{column: column, row: row})}
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
    <th class={align_class(@column)}>
      <button
        type="button"
        phx-click={@sort_event}
        phx-value-key={@column.key}
        class={[
          "hover:text-base-content inline-flex items-center gap-1 transition-colors",
          @active? && "text-base-content",
          not @active? && "text-base-content/70"
        ]}
        aria-label={"Sort by #{@column.label}"}
      >
        {@column.label}
        <%!-- Only chevron-right ships as an icon; rotate it to point down/up. --%>
        <.icon
          :if={@active?}
          name="icon-chevron-right"
          class={["size-3.5", if(@direction == :desc, do: "rotate-90", else: "-rotate-90")]}
        />
      </button>
    </th>
    """
  end

  defp column_header(assigns) do
    ~H"""
    <th class={["text-base-content/70", align_class(@column)]}>{@column.label}</th>
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
        Showing <span class="font-mono">{Formatters.format_integer(@first)}</span>–<span class="font-mono">{Formatters.format_integer(@last)}</span>
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
        <span class="join-item btn btn-sm btn-ghost pointer-events-none font-mono">
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
  Caption describing the scan behind the current result set.

  Ranking runs over the scanned population, so a truncated scan is surfaced
  explicitly rather than implying the list is exhaustive.
  """
  attr :id, :string, required: true
  attr :shown, :integer, required: true
  attr :scanned, :integer, required: true
  attr :truncated?, :boolean, default: false
  attr :last_updated, :any, default: nil

  def scan_summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
      <span>
        Ranked <span class="font-mono">{Formatters.format_integer(@shown)}</span>
        of <span class="font-mono">{Formatters.format_integer(@scanned)}</span> scanned
      </span>
      <span :if={@truncated?} class="badge badge-warning badge-soft badge-xs">truncated</span>
      <span :if={@last_updated} class="text-base-content/60">
        · updated {Formatters.format_time(@last_updated)}
      </span>
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
end
