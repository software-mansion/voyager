defmodule VoyagerWeb.EtsTablesLive do
  @moduledoc """
  Lists the ETS tables of the connected node with their metadata.

  `Fetcher` owns the fetch; one fetch returns every table, so searching,
  sorting and paging all work on the last result and never touch the node.

  Selecting a table opens its basics in the side panel, from which its details
  page is a step away. The selection lives in `?table=` as the table's name or
  inspect-string and is resolved against every fetch, so a table that
  disappears is reported rather than shown stale.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.EtsTablesLive.Fetcher
  alias VoyagerWeb.EtsTablesLive.Query
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsTableListControls
  alias VoyagerWeb.Utils.URL

  @page_sizes [10, 25, 50, 100]
  @default_page_size 25

  @impl true
  def mount(_params, _session, socket) do
    controls = EtsTableListControls.default()
    {sort_by, direction} = Query.default_sort()

    socket
    |> assign(:active_nav, :ets_tables)
    |> assign(:tables, [])
    |> assign(:controls, controls)
    |> assign(:columns, EtsTableListControls.columns(controls))
    |> assign(:form, to_form(EtsTableListControls.changeset(controls), as: :controls))
    |> assign(:sort_by, sort_by)
    |> assign(:direction, direction)
    |> assign(:page, 1)
    |> assign(:page_size, @default_page_size)
    |> assign(:page_sizes, @page_sizes)
    |> Fetcher.init()
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket
    |> assign(:table_param, table_param(params))
    |> resolve_selection()
    |> noreply()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="ets-tables" class="relative flex h-full overflow-hidden">
      <div class="min-w-0 flex-1 overflow-auto">
        <%!-- The hook restores saved controls on mount and stores them on change. --%>
        <div
          id="ets-tables-page"
          phx-hook="TableSettings"
          data-settings-key="ets-tables"
          class={[
            "mx-auto flex h-full max-w-screen-2xl flex-col gap-3 p-6 pb-12 sm:p-8 sm:pb-12",
            DataTableComponents.page_min_width_class()
          ]}
        >
          <.node_header
            node_name={@session.node_name}
            last_updated={@last_updated}
            waiting_message="waiting for first fetch…"
          >
            <:actions>
              <.interval_select
                id="ets-tables-refresh-interval"
                options={Fetcher.interval_options()}
                refresh_interval={@refresh_interval}
                loading={Fetcher.loading?(@page_result)}
              />
            </:actions>
          </.node_header>

          <EtsTableComponents.controls form={@form} />

          <%!-- Outside any loading branch: a refetch swaps rows, not the table. --%>
          <.error_state
            :if={@page_result.failed}
            id="ets-tables-error"
            message={format_error(@page_result.failed)}
          />

          <EtsTableComponents.summary
            :if={@page_result.ok?}
            id="ets-tables-summary"
            shown={@shown_count}
            total={@total_count}
            total_memory={@total_memory}
            round_trip_ms={@round_trip_ms}
          />

          <div class="flex min-h-0 flex-1 flex-col gap-2">
            <DataTableComponents.table
              id="ets-tables-table"
              columns={EtsTableComponents.columns(@columns)}
              rows={rows(@tables, @page, @page_size)}
              sort_by={@sort_by}
              direction={@direction}
              row_class={&row_class(&1, @selected_table)}
              empty_message={empty_message(@page_result)}
            >
              <:cell :let={%{column: column, row: row, row_id: row_id}}>
                <EtsTableComponents.cell
                  column={column}
                  row={row}
                  row_id={row_id}
                  table_href={table_path(@current_url, row)}
                  details_href={details_path(@session.node_name, row)}
                  owner_href={process_path(@session.node_name, row.owner)}
                />
              </:cell>
            </DataTableComponents.table>

            <DataTableComponents.pager
              :if={@page_result.ok?}
              id="ets-tables-pager"
              page={@page}
              page_size={@page_size}
              page_size_options={@page_sizes}
              total={@shown_count}
            />
          </div>
        </div>
      </div>

      <EtsTableComponents.details_panel
        id="ets-table-details"
        table_param={@table_param}
        table={@selected_table}
        fetch_status={fetch_status(@page_result)}
        owner_href={@selected_table && process_path(@session.node_name, @selected_table.owner)}
        details_href={@selected_table && details_path(@session.node_name, @selected_table)}
      />
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"controls" => params}, socket) do
    previous = socket.assigns.controls

    socket
    |> apply_controls(params)
    |> reset_page_if_search_changed(previous.search)
    |> refetch_if_timeout_changed(previous.timeout)
    |> refresh_view()
    |> store_settings(params)
    |> noreply()
  end

  # A debounced change can arrive after the form was patched, without the
  # nested params.
  def handle_event("validate", _params, socket), do: noreply(socket)

  # The client's stored controls, empty when it has none; the first fetch
  # waits for them.
  def handle_event("restore_settings", params, socket) when is_map(params) do
    socket
    |> assign(:page_size, page_size(parse_integer(params["page_size"])))
    |> apply_controls(params)
    |> refresh_view()
    |> Fetcher.start()
    |> noreply()
  end

  # Anything else is a hand-edited or stale storage entry.
  def handle_event("restore_settings", _params, socket) do
    socket
    |> Fetcher.start()
    |> noreply()
  end

  def handle_event("sort", %{"key" => key}, socket) do
    # Matched as a string: `String.to_existing_atom/1` raises on an unknown key.
    case Enum.find(Query.sortable_attrs(), &(to_string(&1) == key)) do
      nil ->
        noreply(socket)

      key ->
        socket
        |> assign(:direction, toggle_direction(socket, key))
        |> assign(:sort_by, key)
        |> assign(:page, 1)
        |> refresh_view()
        |> noreply()
    end
  end

  def handle_event("set_page_size", %{"page_size" => size}, socket) do
    size = page_size(parse_integer(size))

    socket
    |> assign(:page_size, size)
    |> assign(:page, clamp_page(1, length(socket.assigns.tables), size))
    |> store_settings()
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_integer(page) || socket.assigns.page

    socket
    |> assign(:page, clamp_page(page, length(socket.assigns.tables), socket.assigns.page_size))
    |> noreply()
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> Fetcher.set_interval(value)
    |> noreply()
  end

  def handle_event("refresh_now", _params, socket) do
    socket
    |> Fetcher.fetch()
    |> noreply()
  end

  def handle_event("close-details-panel", _params, socket) do
    socket
    |> push_patch(to: URL.drop_query_param(socket.assigns.current_url, "table"))
    |> noreply()
  end

  # `Fetcher` has already applied the result; the rows on screen and the
  # selection are both derived from it.
  @impl true
  def handle_async(:page_result, _result, socket) do
    socket
    |> refresh_view()
    |> resolve_selection()
    |> noreply()
  end

  defp apply_controls(socket, params) do
    {controls, changeset} = EtsTableListControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:columns, EtsTableListControls.columns(controls))
    |> assign(:form, to_form(changeset, as: :controls))
    |> keep_sort_visible()
  end

  # A hidden column cannot show its arrow, so rows ordered by it would look
  # unordered; the sort falls back to memory, which is always shown.
  defp keep_sort_visible(socket) do
    if socket.assigns.sort_by in socket.assigns.columns do
      socket
    else
      {sort_by, direction} = Query.default_sort()

      socket
      |> assign(:sort_by, sort_by)
      |> assign(:direction, direction)
    end
  end

  # A new search narrows to a different set of rows, so it starts from the
  # first page; a timeout edit changes nothing on screen and keeps the page.
  defp reset_page_if_search_changed(socket, previous_search) do
    if socket.assigns.controls.search == previous_search,
      do: socket,
      else: assign(socket, :page, 1)
  end

  # Search and columns are local; only the timeout changes what the node is
  # asked, so only it earns a debounced refetch.
  defp refetch_if_timeout_changed(socket, previous_timeout) do
    if socket.assigns.controls.timeout == previous_timeout,
      do: socket,
      else: Fetcher.debounce_refetch(socket)
  end

  # Search and sort apply to the last fetch, so a change to either only
  # recomputes the rows on screen.
  defp refresh_view(socket) do
    %{controls: controls, sort_by: sort_by, direction: direction, page_size: page_size} =
      socket.assigns

    entries = Fetcher.entries(socket.assigns.page_result)

    tables =
      entries
      |> Query.filter(controls.search)
      |> Query.sort(sort_by, direction)

    socket
    |> assign(:tables, tables)
    |> assign(:shown_count, length(tables))
    |> assign(:total_count, length(entries))
    |> assign(:total_memory, Query.total_memory(entries))
    |> assign(:page, clamp_page(socket.assigns.page, length(tables), page_size))
  end

  # The param is matched against the last fetch rather than looked up on the
  # node: an unnamed table's reference is only meaningful from that list.
  defp resolve_selection(%{assigns: %{table_param: nil}} = socket) do
    assign(socket, :selected_table, nil)
  end

  defp resolve_selection(socket) do
    case Query.find(Fetcher.entries(socket.assigns.page_result), socket.assigns.table_param) do
      {:ok, table} -> assign(socket, :selected_table, table)
      :error -> assign(socket, :selected_table, nil)
    end
  end

  # Only validated values are stored, so nothing invalid comes back next visit.
  # `search` is stored as typed: trimming it would fight the user mid-word.
  defp store_settings(socket, params \\ %{}) do
    %{controls: controls, page_size: page_size} = socket.assigns

    push_event(socket, "store-settings", %{
      settings: %{
        "search" => params["search"] || controls.search,
        "timeout" => to_string(controls.timeout),
        "columns" => controls.columns,
        "page_size" => to_string(page_size)
      }
    })
  end

  defp fetch_status(%AsyncResult{ok?: true}), do: :fetched
  defp fetch_status(%AsyncResult{failed: nil}), do: :pending
  defp fetch_status(_page_result), do: :failed

  defp empty_message(page_result) do
    case fetch_status(page_result) do
      :fetched -> "No tables matched."
      :pending -> "Fetching tables…"
      :failed -> "Nothing fetched yet."
    end
  end

  defp rows(tables, page, page_size) do
    tables
    |> Enum.slice((page - 1) * page_size, page_size)
    |> Enum.map(&{row_dom_id(&1.id), &1})
  end

  @doc false
  # A name can hold any character and a reference inspects as
  # `#Reference<0.1.2.3>`, neither of which is a usable DOM id. The readable
  # part is for the eye; the digest keeps apart two names that only differ in
  # the characters it dropped, and the prefix keeps rows out of the page's own
  # `ets-*` ids.
  def row_dom_id(id) when is_atom(id) or is_reference(id) do
    display = TableId.display(id)

    "ets-row-#{dom_safe(display)}-#{id |> :erlang.phash2() |> Integer.to_string(36)}"
  end

  defp dom_safe(string) do
    string |> String.replace(~r/[^\w-]+/u, "-") |> String.trim("-")
  end

  defp row_class(_row, nil), do: nil
  defp row_class(row, %{id: selected_id}), do: row.id == selected_id && "bg-primary/5"

  defp table_path(url, table) do
    URL.put_query_param(url, "table", TableId.display(table.id))
  end

  defp details_path(node_name, table) do
    ~p"/node/#{node_name}/ets-tables/#{TableId.display(table.id)}"
  end

  defp process_path(node_name, pid) do
    ~p"/node/#{node_name}/processes/#{Formatters.format_pid(pid)}"
  end

  defp table_param(%{"table" => param}) when is_binary(param) and param != "", do: param
  defp table_param(_params), do: nil

  # Re-selecting the active column flips the direction; a new column starts
  # from the order that reads naturally for it: largest first for the numbers,
  # alphabetical for the rest.
  defp toggle_direction(%{assigns: %{sort_by: key, direction: :desc}}, key), do: :asc
  defp toggle_direction(%{assigns: %{sort_by: key}}, key), do: :desc
  defp toggle_direction(_socket, key) when key in [:size, :memory], do: :desc
  defp toggle_direction(_socket, _key), do: :asc

  defp clamp_page(page, total, page_size) do
    page |> max(1) |> min(max(div(total + page_size - 1, page_size), 1))
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp page_size(size) when size in @page_sizes, do: size
  defp page_size(_size), do: @default_page_size

  # Only reached with no rows to fall back on, so unlike the flash it advises.
  defp format_error(:timeout), do: "Request timed out. Try a longer timeout."
  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and refresh."
  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(_reason), do: "Failed to list ETS tables."
end
