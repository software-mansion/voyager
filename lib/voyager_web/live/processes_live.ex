defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  `Fetcher` owns the scan. This view owns the controls, the sort, and a local
  page over whatever the last scan returned — a display slice, separate from
  the fetch limit paid on the node.
  """

  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.ProcessListControls
  alias VoyagerWeb.ProcessesLive.Fetcher
  alias VoyagerWeb.ProcessesLive.Query

  @page_sizes [10, 25, 50, 100]
  @default_page_size 25

  @impl true
  def mount(_params, _session, socket) do
    controls = ProcessListControls.default()
    {sort_by, direction} = Query.default_sort()

    socket
    |> assign(:active_nav, :processes)
    |> assign(:controls, controls)
    |> assign(:form, to_form(ProcessListControls.changeset(controls), as: :controls))
    |> assign(:sort_by, sort_by)
    |> assign(:direction, direction)
    |> assign(:page, 1)
    |> assign(:page_size, @default_page_size)
    |> assign(:page_sizes, @page_sizes)
    |> Fetcher.init()
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
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
          <.interval_select
            id="processes-refresh-interval"
            options={Fetcher.interval_options()}
            refresh_interval={@refresh_interval}
            loading={Fetcher.loading?(@page_result)}
          />
        </:actions>
      </.node_header>

      <ProcessComponents.controls
        form={@form}
        node_name={@session.node_name}
        loading?={@dirty? and Fetcher.loading?(@page_result)}
      />

      <.error_state
        :if={@page_result.failed}
        id="processes-error"
        message={format_error(@page_result.failed)}
      />

      <ProcessComponents.scan_summary
        :if={@page_result.ok?}
        id="processes-scan-summary"
        shown={length(Fetcher.entries(@page_result))}
        scanned={@page_result.result.scanned}
        round_trip_ms={@round_trip_ms}
      />

      <div class={@dirty? && "pointer-events-none select-none opacity-60"}>
        <DataTableComponents.table
          id="processes-table"
          columns={ProcessComponents.columns(ProcessListControls.attrs(@fetched_with))}
          rows={rows(Fetcher.entries(@page_result), @page, @page_size)}
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
          total={length(Fetcher.entries(@page_result))}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"controls" => params}, socket) do
    socket
    |> apply_controls(params)
    |> store_settings(params)
    |> Fetcher.debounce_refetch()
    |> noreply()
  end

  # A debounced change can arrive after the form was patched, without the
  # nested params.
  def handle_event("validate", _params, socket), do: noreply(socket)

  # The client's stored controls, empty when it has none.
  # Mount doesn't start fetch
  def handle_event("restore_settings", params, socket) when is_map(params) do
    socket
    |> assign(:page_size, page_size(parse_integer(params["page_size"])))
    |> apply_controls(params)
    |> Fetcher.start()
    |> noreply()
  end

  # Anything else is a hand-edited or stale storage entry. The defaults still
  # need their scan, or the page would wait on a fetch that never starts.
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
        |> Fetcher.fetch()
        |> noreply()
    end
  end

  def handle_event("set_page_size", %{"page_size" => size}, socket) do
    size = page_size(parse_integer(size))

    socket
    |> assign(:page_size, size)
    |> assign(:page, clamp_page(1, total(socket), size))
    |> store_settings()
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_integer(page) || socket.assigns.page

    socket
    |> assign(:page, clamp_page(page, total(socket), socket.assigns.page_size))
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

  # `Fetcher` has already applied the result; a smaller one can leave the
  # local page past the end.
  @impl true
  def handle_async(:page_result, _result, socket) do
    socket
    |> assign(:page, clamp_page(socket.assigns.page, total(socket), socket.assigns.page_size))
    |> noreply()
  end

  defp apply_controls(socket, params) do
    {controls, changeset} = ProcessListControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :controls))
    |> assign(:page, 1)
  end

  # Only validated values are stored, so nothing invalid comes back next visit.
  # `search` is stored as typed: trimming it would fight the user mid-word.
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

  defp total(%{assigns: %{page_result: page_result}}) do
    length(Fetcher.entries(page_result))
  end

  # The remote already returned them ranked; paging only walks that result.
  defp rows(entries, page, page_size) do
    entries
    |> Enum.slice((page - 1) * page_size, page_size)
    |> Enum.map(&{row_dom_id(&1.pid), &1})
  end

  # `<0.123.0>` is not a usable DOM id, so reduce a pid to `process-0-123-0`.
  defp row_dom_id(pid) do
    digits = pid |> Formatters.format_pid() |> String.replace(~r/[^\d]+/, "-") |> String.trim("-")
    "process-#{digits}"
  end

  defp process_path(node_name, pid) do
    ~p"/node/#{node_name}/processes/#{Formatters.format_pid(pid)}"
  end

  # Re-selecting the active column flips the direction; a new column starts
  # descending, the useful default for every numeric metric here.
  defp toggle_direction(%{assigns: %{sort_by: key, direction: :desc}}, key), do: :asc
  defp toggle_direction(_socket, _key), do: :desc

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
  defp format_error(:timeout), do: "Request timed out. Try a longer timeout or a smaller limit."
  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and refresh."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to list processes."
end
