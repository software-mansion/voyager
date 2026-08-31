defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  Every refresh is a full scan of the remote process table, so auto-refresh is
  opt-in and defaults to off. Sorting, searching, the fetch size and the chosen
  columns all run on the remote node and therefore trigger a new fetch, while
  paging walks the already-fetched rows locally.

  Two separate sizes: `limit` is how many rows the remote fetches (a cost paid
  on the node and over the wire), while `page_size` only slices those rows for
  display. Both, plus the timeout and the selected columns, are kept in the
  query string so a configured view survives a reload, can be shared as a link,
  and is restored when returning from a process's details page.
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
    |> assign(:selected_attrs, Processes.default_attrs())
    |> assign(:refresh_interval, nil)
    |> assign(:refresh_timer, nil)
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

    attrs = param_attrs(params["columns"], socket.assigns.selected_attrs)

    refetch? =
      limit != socket.assigns.limit or timeout != socket.assigns.timeout or
        attrs != socket.assigns.selected_attrs

    socket =
      socket
      |> assign(:limit, limit)
      |> assign(:timeout, timeout)
      |> assign(:page_size, page_size)
      |> assign(:selected_attrs, attrs)

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
        searching and changing the columns or how many processes to fetch re-run
        the scan; changing rows per page or moving between pages does not. Figures are a
        snapshot from the last fetch, not a live view.
      </DataTableComponents.info_note>

      <DataTableComponents.toolbar
        id="processes-toolbar"
        search={@search}
        search_placeholder="Search by PID, name or initial call"
        limit={@limit}
        limit_options={Processes.limit_options()}
        limit_label="Fetch"
        page_size={@page_size}
        page_size_options={Processes.page_size_options()}
        columns_options={column_options()}
        columns_selected={Enum.map(@selected_attrs, &to_string/1)}
        timeout={@timeout}
        timeout_min={elem(Processes.timeout_bounds(), 0)}
        timeout_max={elem(Processes.timeout_bounds(), 1)}
        refresh_interval={@refresh_interval}
        refresh_interval_options={Processes.refresh_interval_options()}
        loading?={@page_result.loading}
      />

      <%!-- The table is rendered outside any loading branch so a refetch only
            swaps the rows inside it; replacing the whole block tore the table
            down and rebuilt it, which flickered. --%>
      <.error_state
        :if={failed_reason(@page_result)}
        id="processes-error"
        message={format_error(failed_reason(@page_result))}
      />

      <DataTableComponents.scan_summary
        :if={@page_result.ok?}
        id="processes-scan-summary"
        shown={length(@page_result.result.entries)}
        scanned={@page_result.result.scanned}
        truncated?={@page_result.result.truncated?}
        last_updated={@last_updated}
      />

      <DataTableComponents.table
        id="processes-table"
        columns={ProcessComponents.columns(@selected_attrs)}
        rows={rows(current_entries(@page_result), @page, @page_size)}
        sort_by={@sort_by}
        direction={@direction}
        row_click_event="select-process"
        row_id_key={:pid}
        empty_message={if @page_result.ok?, do: "No processes matched.", else: "Scanning processes…"}
        min_rows={@page_size}
        resizable?={true}
      >
        <:cell :let={%{column: column, row: row}}>
          <ProcessComponents.cell column={column} row={row} />
        </:cell>
      </DataTableComponents.table>

      <DataTableComponents.pager
        :if={@page_result.ok?}
        id="processes-pager"
        page={@page}
        page_size={@page_size}
        total={length(@page_result.result.entries)}
      />
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

  def handle_event("set_timeout", %{"timeout" => ms}, socket) do
    timeout = ms |> parse_integer(socket.assigns.timeout) |> Processes.clamp_timeout()

    socket
    |> push_patch(to: controls_path(socket, %{"timeout" => to_string(timeout)}))
    |> noreply()
  end

  def handle_event("set_columns", params, socket) do
    selected =
      params
      |> Map.get("columns", [])
      |> param_attr_list()
      |> Processes.clamp_attrs()

    socket
    |> push_patch(to: controls_path(socket, %{"columns" => Enum.join(selected, ",")}))
    |> noreply()
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> restart_refresh_timer()
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
    # The configured view (columns, limit, page size, timeout) lives in the
    # query string, so it is carried along for the details page's back link.
    node_name = socket.assigns.session.node_name
    return_to = socket.assigns.current_url

    socket
    |> push_navigate(to: ~p"/node/#{node_name}/processes/#{pid_string}?#{[return_to: return_to]}")
    |> noreply()
  end

  @impl true
  def handle_info(:auto_refresh, socket) do
    socket = restart_refresh_timer(socket)

    if socket.assigns.page_result.loading do
      socket
    else
      fetch(socket)
    end
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
    attrs = socket.assigns.selected_attrs

    # The previous result stays assigned while a refetch runs, so the table
    # keeps its rows instead of being torn down and rebuilt (which flickered).
    socket
    |> start_async(:page_result, fn ->
      case Processes.page(session.node,
             sort_by: sort_by,
             direction: direction,
             limit: limit,
             timeout: timeout,
             search: search,
             attrs: attrs
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

  # `{value, label, locked?}` triples for the columns multiselect, required
  # attributes first so they read as the fixed part of the selection.
  defp column_options do
    required = Enum.map(Processes.required_attrs(), &{to_string(&1), label(&1), true})
    optional = Enum.map(Processes.optional_attrs(), &{to_string(&1), label(&1), false})

    required ++ optional
  end

  defp label(attr), do: ProcessComponents.column_label(attr)

  # Names come from the client, so only known attributes are converted; anything
  # else is dropped rather than creating an atom.
  defp param_attr_list(names) do
    known = Processes.required_attrs() ++ Processes.optional_attrs()

    names
    |> Enum.map(fn name -> Enum.find(known, &(to_string(&1) == name)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_interval("off"), do: nil

  defp parse_interval(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp restart_refresh_timer(socket) do
    if timer = socket.assigns.refresh_timer, do: Process.cancel_timer(timer)

    case socket.assigns.refresh_interval do
      nil -> assign(socket, :refresh_timer, nil)
      ms -> assign(socket, :refresh_timer, Process.send_after(self(), :auto_refresh, ms))
    end
  end

  # Columns arrive as a comma-separated query param; unknown names are dropped
  # and the required ones are always re-added.
  defp param_attrs(nil, fallback), do: Processes.clamp_attrs(fallback)

  defp param_attrs(value, _fallback) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> param_attr_list()
    |> Processes.clamp_attrs()
  end

  # Rows survive a refetch: the previous result stays assigned, so the table
  # keeps rendering it until the new one lands.
  defp current_entries(%AsyncResult{ok?: true, result: %{entries: entries}}), do: entries
  defp current_entries(_page_result), do: []

  # A failure keeps whatever rows were already on screen, so the error is shown
  # above them rather than replacing them.
  defp failed_reason(%AsyncResult{failed: nil}), do: nil
  defp failed_reason(%AsyncResult{failed: reason}), do: reason

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
