defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  Fetching is manual: every refresh is a full scan of the remote process table,
  so nothing is fetched on a timer. Sorting, searching and the result size all
  run on the remote node and therefore trigger a new fetch, while paging walks
  the already-fetched rows locally.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents

  require Logger

  @page_size 25

  @timeout_options [
    {"1s", "1000"},
    {"3s", "3000"},
    {"5s", "5000"},
    {"10s", "10000"},
    {"30s", "30000"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :processes)
      |> assign(:page_result, AsyncResult.loading())
      |> assign(:sort_by, Processes.default_sort_by())
      |> assign(:direction, Processes.default_direction())
      |> assign(:limit, Processes.default_limit())
      |> assign(:timeout, Processes.default_timeout())
      |> assign(:search, "")
      |> assign(:page, 1)
      |> assign(:page_size, @page_size)
      |> assign(:last_updated, nil)

    if connected?(socket) do
      fetch(socket)
    else
      socket
    end
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col gap-4 p-6 sm:p-8">
      <.node_header
        node_name={@session.node_name}
        last_updated={@last_updated}
        waiting_message="waiting for first fetch…"
      />

      <DataTableComponents.toolbar
        id="processes-toolbar"
        search={@search}
        search_placeholder="Search by PID, name or initial call"
        limit={@limit}
        limit_options={Processes.limit_options()}
        limit_label="Processes"
        timeout={@timeout}
        timeout_options={timeout_options()}
        loading?={@page_result.loading}
      />

      <.async_result :let={result} assign={@page_result}>
        <:loading>
          <.loading_state id="processes-loading" message="Scanning processes…" />
        </:loading>
        <:failed :let={reason}>
          <.error_state id="processes-error" message={format_error(reason)} />
        </:failed>

        <DataTableComponents.scan_summary
          id="processes-scan-summary"
          shown={length(result.entries)}
          scanned={result.scanned}
          truncated?={result.truncated?}
          last_updated={@last_updated}
        />

        <DataTableComponents.table
          id="processes-table"
          columns={ProcessComponents.columns()}
          rows={rows(result.entries, @page)}
          sort_by={@sort_by}
          direction={@direction}
          row_click_event="select-process"
          row_id_key={:pid}
          empty_message="No processes matched."
        >
          <:cell :let={%{column: column, row: row}}>
            <ProcessComponents.cell column={column} row={row} />
          </:cell>
        </DataTableComponents.table>

        <DataTableComponents.pager
          id="processes-pager"
          page={@page}
          page_size={@page_size}
          total={length(result.entries)}
        />
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    key = String.to_existing_atom(key)

    if key in Processes.sortable_attrs() do
      socket
      |> assign(:direction, toggle_direction(socket, key))
      |> assign(:sort_by, key)
      |> assign(:page, 1)
      |> fetch()
    else
      socket
    end
    |> noreply()
  end

  def handle_event("search", %{"search" => search}, socket) do
    if search == socket.assigns.search do
      socket
    else
      socket
      |> assign(:search, search)
      |> assign(:page, 1)
      |> fetch()
    end
    |> noreply()
  end

  def handle_event("set_limit", %{"limit" => limit}, socket) do
    socket
    |> assign(:limit, parse_integer(limit, socket.assigns.limit))
    |> assign(:page, 1)
    |> fetch()
    |> noreply()
  end

  def handle_event("set_timeout", %{"timeout" => timeout}, socket) do
    socket
    |> assign(:timeout, parse_integer(timeout, socket.assigns.timeout))
    |> noreply()
  end

  def handle_event("refresh", _params, socket) do
    socket
    |> fetch()
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    socket
    |> assign(:page, clamp_page(socket, parse_integer(page, socket.assigns.page)))
    |> noreply()
  end

  def handle_event("select-process", %{"id" => pid_string}, socket) do
    socket
    |> push_navigate(
      to: ~p"/node/#{socket.assigns.session.node_name}/processes/#{pid_string}"
    )
    |> noreply()
  end

  @impl true
  def handle_async(:page_result, {:ok, {:ok, %{page_result: page}}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.ok(socket.assigns.page_result, page))
    |> assign(:last_updated, page.fetched_at)
    |> assign(:page, clamp_page_to(socket.assigns.page, length(page.entries)))
    |> noreply()
  end

  def handle_async(:page_result, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
    |> noreply()
  end

  def handle_async(:page_result, {:exit, reason}, socket) do
    socket
    |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
    |> noreply()
  end

  defp fetch(socket) do
    %{session: session, sort_by: sort_by, direction: direction} = socket.assigns
    %{limit: limit, timeout: timeout, search: search} = socket.assigns

    socket
    |> assign(:page_result, AsyncResult.loading())
    |> assign_async(:page_result, fn ->
      case Processes.page(session.node,
             sort_by: sort_by,
             direction: direction,
             limit: limit,
             timeout: timeout,
             search: search
           ) do
        {:ok, page} ->
          {:ok, %{page_result: page}}

        {:error, reason} ->
          Logger.warning(
            "Failed to list processes on #{inspect(session.node)}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end)
  end

  # The remote already returned them ranked; paging only walks that result.
  defp rows(entries, page) do
    entries
    |> Enum.slice((page - 1) * @page_size, @page_size)
    |> Enum.map(&{"process-#{Processes.format_pid(&1.pid)}", &1})
  end

  # Re-selecting the active column flips the direction; a new column starts
  # descending, which is the useful default for every numeric metric here.
  defp toggle_direction(%{assigns: %{sort_by: key, direction: :desc}}, key), do: :asc
  defp toggle_direction(%{assigns: %{sort_by: key}}, key) when is_atom(key), do: :desc
  defp toggle_direction(_socket, _key), do: :desc

  defp clamp_page(socket, page) do
    total =
      case socket.assigns.page_result do
        %AsyncResult{ok?: true, result: %{entries: entries}} -> length(entries)
        _ -> 0
      end

    clamp_page_to(page, total)
  end

  defp clamp_page_to(page, total) do
    total_pages = max(div(total + @page_size - 1, @page_size), 1)

    page |> max(1) |> min(total_pages)
  end

  defp parse_integer(value, fallback) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end

  defp timeout_options, do: @timeout_options

  defp format_error(:timeout),
    do: "Timed out while scanning processes. Try a longer timeout or fewer processes."

  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to list processes."
end
