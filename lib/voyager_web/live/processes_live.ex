defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  Fetching is manual: every refresh is a full scan of the remote process table,
  so nothing is fetched on a timer. Sorting, searching and the result size all
  run on the remote node and therefore trigger a new fetch, while paging walks
  the already-fetched rows locally.

  Two separate sizes: `limit` is how many rows the remote fetches (a cost paid
  on the node and over the wire), while `page_size` only slices those rows for
  display. Both, plus the request timeout, are kept in the query string so a
  configured view survives a reload and can be shared as a link.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Utils.URL

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :processes)
    |> assign(:page_result, AsyncResult.loading())
    |> assign(:sort_by, Processes.default_sort_by())
    |> assign(:direction, Processes.default_direction())
    |> assign(:limit, Processes.default_limit())
    |> assign(:timeout, Processes.default_timeout())
    |> assign(:search, "")
    |> assign(:page, 1)
    |> assign(:page_size, Processes.default_page_size())
    |> assign(:last_updated, nil)
    |> assign(:params_applied?, false)
    |> ok()
  end

  # The URL is the source of truth for the controls, so the first fetch waits
  # for handle_params rather than firing with the defaults and again with the
  # real values. Only `limit`/`timeout` reach the remote; `page_size` slices
  # what was already fetched, so changing it must not trigger a refetch.
  @impl true
  def handle_params(params, _uri, socket) do
    limit = Processes.clamp_limit(param_integer(params["limit"], socket.assigns.limit))
    timeout = Processes.clamp_timeout(param_integer(params["timeout"], socket.assigns.timeout))

    page_size =
      Processes.clamp_page_size(param_integer(params["page_size"], socket.assigns.page_size))

    refetch? = limit != socket.assigns.limit or timeout != socket.assigns.timeout

    socket =
      socket
      |> assign(:limit, limit)
      |> assign(:timeout, timeout)
      |> assign(:page_size, page_size)

    # Clamped after page_size is assigned: a larger page size means fewer pages.
    socket = assign(socket, :page, clamp_page(socket, socket.assigns.page))

    if connected?(socket) and (refetch? or not socket.assigns.params_applied?) do
      socket
      |> assign(:params_applied?, true)
      |> assign(:page, 1)
      |> fetch()
    else
      socket
    end
    |> noreply()
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

      <DataTableComponents.info_note id="processes-info">
        Processes are fetched from the remote node once per refresh — ranked and
        limited on the node itself — and then paged here in the browser. Sorting,
        searching and changing how many processes to fetch re-run the scan;
        changing rows per page or moving between pages does not. Figures are a
        snapshot from the last fetch, not a live view.
      </DataTableComponents.info_note>

      <DataTableComponents.toolbar
        id="processes-toolbar"
        search={@search}
        search_placeholder="Search by PID, name or initial call"
        limit={@limit}
        limit_min={elem(Processes.limit_bounds(), 0)}
        limit_max={elem(Processes.limit_bounds(), 1)}
        limit_label="Fetch"
        page_size={@page_size}
        page_size_options={Processes.page_size_options()}
        timeout={timeout_seconds(@timeout)}
        timeout_min={timeout_seconds(elem(Processes.timeout_bounds(), 0))}
        timeout_max={timeout_seconds(elem(Processes.timeout_bounds(), 1))}
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
          rows={rows(result.entries, @page, @page_size)}
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

  # Both controls live in the query string: patch the URL and let
  # handle_params/3 apply the value and trigger the refetch.
  def handle_event("set_limit", %{"limit" => limit}, socket) do
    limit = limit |> parse_integer(socket.assigns.limit) |> Processes.clamp_limit()

    socket
    |> push_patch(to: controls_path(socket, %{"limit" => to_string(limit)}))
    |> noreply()
  end

  def handle_event("set_page_size", %{"page_size" => page_size}, socket) do
    page_size =
      page_size |> parse_integer(socket.assigns.page_size) |> Processes.clamp_page_size()

    socket
    |> push_patch(to: controls_path(socket, %{"page_size" => to_string(page_size)}))
    |> noreply()
  end

  def handle_event("set_timeout", %{"timeout" => seconds}, socket) do
    timeout =
      seconds
      |> parse_integer(timeout_seconds(socket.assigns.timeout))
      |> timeout_ms()
      |> Processes.clamp_timeout()

    socket
    |> push_patch(to: controls_path(socket, %{"timeout" => to_string(timeout)}))
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
    |> push_navigate(to: ~p"/node/#{socket.assigns.session.node_name}/processes/#{pid_string}")
    |> noreply()
  end

  @impl true
  def handle_async(:page_result, {:ok, {:ok, page}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.ok(socket.assigns.page_result, page))
    |> assign(:last_updated, page.fetched_at)
    |> assign(
      :page,
      clamp_page_to(socket.assigns.page, length(page.entries), socket.assigns.page_size)
    )
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

    # start_async (not assign_async): the result is handled in handle_async/3
    # above, which also stamps `last_updated` from the completed fetch.
    socket
    |> assign(:page_result, AsyncResult.loading())
    |> start_async(:page_result, fn ->
      case Processes.page(session.node,
             sort_by: sort_by,
             direction: direction,
             limit: limit,
             timeout: timeout,
             search: search
           ) do
        {:ok, page} ->
          {:ok, page}

        {:error, reason} ->
          Logger.warning(
            "Failed to list processes on #{inspect(session.node)}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end)
  end

  # The remote already returned them ranked; paging only walks that result.
  defp rows(entries, page, page_size) do
    entries
    |> Enum.slice((page - 1) * page_size, page_size)
    |> Enum.map(&{row_dom_id(&1.pid), &1})
  end

  @doc false
  # `<0.123.0>` is not a usable DOM id or CSS selector, so reduce a pid to its
  # digits: `process-0-123-0`.
  def row_dom_id(pid) when is_pid(pid) do
    digits =
      pid
      |> Processes.format_pid()
      |> String.replace(~r/[^\d]+/, "-")
      |> String.trim("-")

    "process-#{digits}"
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

    clamp_page_to(page, total, socket.assigns.page_size)
  end

  defp clamp_page_to(page, total, page_size) do
    total_pages = max(div(total + page_size - 1, page_size), 1)

    page |> max(1) |> min(total_pages)
  end

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end

  defp parse_integer(_value, fallback), do: fallback

  # A blank or malformed query param falls back rather than erroring: the URL is
  # user-editable.
  defp param_integer(nil, fallback), do: fallback
  defp param_integer(value, fallback), do: parse_integer(value, fallback)

  # The remote takes milliseconds; the control is in whole seconds.
  defp timeout_seconds(ms), do: div(ms, 1_000)
  defp timeout_ms(seconds), do: seconds * 1_000

  defp controls_path(socket, params) do
    URL.put_query_params(socket.assigns.current_url, params)
  end

  # `assign_async` wraps a returned `{:error, reason}` before it reaches the
  # `:failed` slot, so unwrap it before matching on the reason itself.
  defp format_error({:error, reason}), do: format_error(reason)

  defp format_error(:timeout),
    do: "Timed out while scanning processes. Try a longer timeout or fewer processes."

  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to list processes."
end
