defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  Every fetch is a full scan of the remote process table, so nothing fetches
  implicitly: the controls form only validates and remembers what the *next*
  fetch will ask for, and the rows change on a manual refresh, on the
  auto-refresh tick, or when a column is sorted.

  Paging is local to whatever the last fetch returned, and is a separate
  setting from the fetch limit — one is a display slice, the other a cost paid
  on the node and over the wire.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.FormSchemas.ProcessListControls

  require Logger

  @page_sizes [10, 25, 50, 100]
  @default_page_size 25
  @refetch_debounce_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    controls = ProcessListControls.default()
    {sort_by, direction} = Processes.default_sort()

    socket
    |> assign(:active_nav, :processes)
    |> assign(:page_result, AsyncResult.loading())
    |> assign(:controls, controls)
    |> assign(:form, to_form(ProcessListControls.changeset(controls), as: :controls))
    |> assign(:refetch_timer, nil)
    |> assign(:fetched_with, controls)
    |> assign(:dirty?, false)
    |> assign(:sort_by, sort_by)
    |> assign(:direction, direction)
    |> assign(:page, 1)
    |> assign(:page_size, @default_page_size)
    |> assign(:page_sizes, @page_sizes)
    |> assign(:refresh_interval, nil)
    |> assign(:refresh_timer, nil)
    |> assign(:last_updated, nil)
    |> then(&if(connected?(&1), do: fetch(&1), else: &1))
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The hook restores the saved controls on mount and stores them on every
          change, so the page comes back configured. --%>
    <div
      id="processes-page"
      phx-hook="TableSettings"
      data-settings-key="processes"
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
          <span
            id="processes-status"
            class={["badge mr-2 dark:text-base-100", status_badge_class(status(@page_result))]}
          >
            {status(@page_result)}
          </span>
          <.interval_select
            id="processes-refresh-interval"
            options={Processes.refresh_interval_options()}
            refresh_interval={@refresh_interval}
            loading={loading?(@page_result)}
          />
        </:actions>
      </.node_header>

      <ProcessComponents.controls
        form={@form}
        node_name={@session.node_name}
        loading?={@dirty? and loading?(@page_result)}
      />

      <%!-- Rendered outside any loading branch: a refetch swaps only the rows,
            rather than tearing the table down and rebuilding it (which
            flickered). --%>
      <.error_state
        :if={@page_result.failed}
        id="processes-error"
        message={format_error(@page_result.failed)}
      />

      <ProcessComponents.scan_summary
        :if={@page_result.ok?}
        id="processes-scan-summary"
        shown={length(entries(@page_result))}
        scanned={@page_result.result.scanned}
      />

      <div class={@dirty? && "pointer-events-none select-none opacity-60"}>
        <DataTableComponents.table
          id="processes-table"
          columns={ProcessComponents.columns(ProcessListControls.attrs(@fetched_with))}
          rows={rows(entries(@page_result), @page, @page_size)}
          sort_by={@sort_by}
          direction={@direction}
          empty_message={
            if @page_result.ok?, do: "No processes matched.", else: "Scanning processes…"
          }
        >
          <:cell :let={%{column: column, row: row, row_id: row_id}}>
            <ProcessComponents.cell
              column={column}
              row={row}
              row_id={row_id}
              pid_href={process_path(@session.node_name, row.pid)}
            />
          </:cell>
        </DataTableComponents.table>

        <DataTableComponents.pager
          :if={@page_result.ok?}
          id="processes-pager"
          page={@page}
          page_size={@page_size}
          page_size_options={@page_sizes}
          total={length(entries(@page_result))}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"controls" => params}, socket) do
    socket
    |> apply_controls(params)
    |> assign(:dirty?, true)
    |> store_settings(params)
    |> debounce_refetch()
    |> noreply()
  end

  # Restored from localStorage on mount: same validation, then a first fetch
  # with the remembered options rather than the defaults.
  def handle_event("restore_settings", params, socket) do
    socket
    |> assign(:page_size, page_size(parse_integer(params["page_size"])))
    |> apply_controls(params)
    |> fetch()
    |> noreply()
  end

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

  def handle_event("set_page_size", %{"page_size" => size}, socket) do
    size = page_size(parse_integer(size))

    socket
    |> assign(:page_size, size)
    |> assign(:page, clamp_page(socket, 1, size))
    |> store_settings()
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_integer(page) || socket.assigns.page

    socket
    |> assign(:page, clamp_page(socket, page, socket.assigns.page_size))
    |> noreply()
  end

  def handle_event("set_interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> restart_refresh_timer()
    |> noreply()
  end

  def handle_event("refresh_now", _params, socket) do
    socket
    |> fetch()
    |> noreply()
  end

  @impl true
  def handle_info(:refetch, socket) do
    socket
    |> assign(:refetch_timer, nil)
    |> fetch()
    |> noreply()
  end

  def handle_info(:auto_refresh, socket) do
    socket = restart_refresh_timer(socket)

    # A tick while a scan is still running is dropped rather than queued.
    if socket.assigns.page_result.loading do
      socket
    else
      fetch(socket)
    end
    |> noreply()
  end

  @impl true
  def handle_async(:page_result, {:ok, {:ok, page, fetched_with}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.ok(socket.assigns.page_result, page))
    |> assign(:fetched_with, fetched_with)
    |> assign(:dirty?, false)
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
    |> assign(:dirty?, false)
    |> noreply()
  end

  def handle_async(:page_result, {:exit, reason}, socket) do
    socket
    |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
    |> noreply()
  end

  defp apply_controls(socket, params) do
    {controls, changeset} = ProcessListControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :controls))
    |> assign(:page, 1)
  end

  defp fetch(socket) do
    %{session: session, controls: controls, sort_by: sort_by, direction: direction} =
      socket.assigns

    # The previous result stays assigned (only marked loading) while a refetch
    # runs, so the table keeps its rows and the UI can lock over them.
    socket
    |> assign(:page_result, AsyncResult.loading(socket.assigns.page_result))
    |> start_async(:page_result, fn ->
      case Processes.page(session.node, controls, {sort_by, direction}) do
        {:ok, page} ->
          {:ok, page, controls}

        {:error, reason} ->
          Logger.warning(
            "Failed to list processes on #{inspect(session.node)}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end)
  end

  # Collapses a burst of control changes into one fetch: each change restarts
  # the window, and the fetch fires once the user pauses.
  defp debounce_refetch(socket) do
    if timer = socket.assigns.refetch_timer, do: Process.cancel_timer(timer)

    assign(socket, :refetch_timer, Process.send_after(self(), :refetch, @refetch_debounce_ms))
  end

  defp loading?(%AsyncResult{loading: loading}), do: loading != nil

  # Same vocabulary as the supervision tree's header badge.
  defp status(%AsyncResult{loading: loading}) when loading != nil, do: :loading
  defp status(%AsyncResult{failed: :timeout}), do: :timeout
  defp status(%AsyncResult{failed: failed}) when failed != nil, do: :error
  defp status(%AsyncResult{ok?: true}), do: :ok
  defp status(_page_result), do: :idle

  defp status_badge_class(:idle), do: "text-base-content!"
  defp status_badge_class(:loading), do: "badge-info"
  defp status_badge_class(:ok), do: "badge-success"
  defp status_badge_class(:timeout), do: "badge-warning"
  defp status_badge_class(:error), do: "badge-error"

  # Only validated values are stored, so nothing invalid can come back on the
  # next visit. `search` is taken as typed, since anything is valid there.
  defp store_settings(socket, params \\ %{}) do
    %{controls: controls, page_size: page_size} = socket.assigns

    push_event(socket, "store-settings", %{
      settings: %{
        "search" => params["search"] || controls.search,
        "limit" => to_string(controls.limit),
        "timeout" => to_string(controls.timeout),
        "columns" => controls.columns,
        "page_size" => to_string(page_size)
      }
    })
  end

  defp entries(%AsyncResult{ok?: true, result: %{entries: entries}}), do: entries
  defp entries(_page_result), do: []

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
    digits = pid |> Processes.format_pid() |> String.replace(~r/[^\d]+/, "-") |> String.trim("-")

    "process-#{digits}"
  end

  defp process_path(node_name, pid) do
    ~p"/node/#{node_name}/processes/#{Processes.format_pid(pid)}"
  end

  # Re-selecting the active column flips the direction; a new column starts
  # descending, which is the useful default for every numeric metric here.
  defp toggle_direction(%{assigns: %{sort_by: key, direction: :desc}}, key), do: :asc
  defp toggle_direction(%{assigns: %{sort_by: key}}, key) when is_atom(key), do: :desc
  defp toggle_direction(_socket, _key), do: :desc

  defp clamp_page(socket, page, page_size) do
    clamp_page_to(page, length(entries(socket.assigns.page_result)), page_size)
  end

  defp clamp_page_to(page, total, page_size) do
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

  defp parse_interval("off"), do: nil
  defp parse_interval(value), do: parse_integer(value)

  defp restart_refresh_timer(socket) do
    if timer = socket.assigns.refresh_timer, do: Process.cancel_timer(timer)

    case socket.assigns.refresh_interval do
      nil -> assign(socket, :refresh_timer, nil)
      ms -> assign(socket, :refresh_timer, Process.send_after(self(), :auto_refresh, ms))
    end
  end

  defp format_error(:timeout),
    do: "Timed out while scanning processes. Try a longer timeout or fewer processes."

  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to list processes."
end
