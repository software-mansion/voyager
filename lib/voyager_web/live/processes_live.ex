defmodule VoyagerWeb.ProcessesLive do
  @moduledoc """
  Lists the top processes of the connected node, ranked remotely.

  Every fetch is a full scan of the remote process table, so fetches are kept
  deliberate: a manual refresh, the auto-refresh tick, a sort, or a change to
  the controls once its debounce window closes — which collapses a burst of
  edits into a single scan.

  Paging is local to whatever the last fetch returned, and is a separate
  setting from the fetch limit — one is a display slice, the other a cost paid
  on the node and over the wire.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.Processes
  alias Voyager.Services.RateLimiter
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.FormSchemas.ProcessListControls

  require Logger

  @page_sizes [10, 25, 50, 100]
  @default_page_size 25
  @refetch_debounce_ms 1_500
  # A fetch resolving in a few ms flashes the loading state for a frame; pad it
  # so the transition reads as intentional. Zeroed in the test env, where the
  # pad would only slow every render_async down.
  @min_fetch_ms Application.compile_env(:voyager, :min_fetch_ms, 300)

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
    |> assign(:refetch_queued?, false)
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
    |> assign(:round_trip_ms, nil)
    |> then(&if(connected?(&1), do: start_fetch(&1, :high), else: &1))
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
        round_trip_ms={@round_trip_ms}
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
    |> store_settings(params)
    |> debounce_refetch()
    |> noreply()
  end

  # An input can fire a debounced change after the form was patched, arriving
  # without the nested params; there is nothing to apply.
  def handle_event("validate", _params, socket), do: noreply(socket)

  # The mount fetch is already running with the defaults, so only rescan when
  # the stored controls would ask the node for something else.
  def handle_event("restore_settings", params, socket) do
    socket = assign(socket, :page_size, page_size(parse_integer(params["page_size"])))
    restored = apply_controls(socket, params)

    if restored.assigns.controls == socket.assigns.controls do
      restored
    else
      fetch(restored)
    end
    |> noreply()
  end

  def handle_event("sort", %{"key" => key}, socket) do
    # Matched as a string: `String.to_existing_atom/1` raises on an unknown key.
    case Enum.find(Processes.sortable_attrs(), &(to_string(&1) == key)) do
      nil ->
        socket

      key ->
        socket
        |> assign(:direction, toggle_direction(socket, key))
        |> assign(:sort_by, key)
        |> assign(:page, 1)
        |> fetch()
    end
    |> noreply()
  end

  def handle_event("set_page_size", %{"page_size" => size}, socket) do
    size = page_size(parse_integer(size))

    socket
    |> assign(:page_size, size)
    |> assign(:page, clamp_page(1, length(entries(socket.assigns.page_result)), size))
    |> store_settings()
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_integer(page) || socket.assigns.page

    socket
    |> assign(
      :page,
      clamp_page(page, length(entries(socket.assigns.page_result)), socket.assigns.page_size)
    )
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
    |> assign(:dirty?, true)
    |> fetch()
    |> noreply()
  end

  def handle_info(:auto_refresh, socket) do
    socket
    |> restart_refresh_timer()
    |> fetch(:low)
    |> noreply()
  end

  @impl true
  def handle_async(:page_result, {:ok, {:ok, page, fetched_with, round_trip_ms}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.ok(socket.assigns.page_result, page))
    |> assign(:fetched_with, fetched_with)
    |> assign(:dirty?, false)
    |> assign(:round_trip_ms, round_trip_ms)
    |> assign(:last_updated, page.fetched_at)
    |> assign(
      :page,
      clamp_page(socket.assigns.page, length(page.entries), socket.assigns.page_size)
    )
    |> drain_queued_refetch()
    |> noreply()
  end

  def handle_async(:page_result, {:ok, :skipped}, socket) do
    socket
    |> clear_loading()
    |> drain_queued_refetch()
    |> noreply()
  end

  # Rate limiting and timeouts are transient, so they flash over rows that are
  # still the last good answer. With nothing on screen there is nothing to keep,
  # and a flash alone would leave the table on its loading text forever.
  def handle_async(:page_result, {:ok, {:rate_limited, _retry_after_ms}}, socket) do
    socket
    |> transient_error(:rate_limited, "Too many requests.")
    |> drain_queued_refetch()
    |> noreply()
  end

  def handle_async(:page_result, {:ok, {:error, :timeout}}, socket) do
    socket
    |> transient_error(:timeout, "Request timed out")
    |> drain_queued_refetch()
    |> noreply()
  end

  # A failed fetch drops the queued replay: the request that was dropped would
  # hit the same failure, and the error on screen is the more useful answer.
  def handle_async(:page_result, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
    |> assign(:dirty?, false)
    |> assign(:refetch_queued?, false)
    |> noreply()
  end

  def handle_async(:page_result, {:exit, reason}, socket) do
    socket
    |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
    |> assign(:dirty?, false)
    |> assign(:refetch_queued?, false)
    |> noreply()
  end

  defp drain_queued_refetch(socket) do
    if socket.assigns.refetch_queued?, do: fetch(socket), else: socket
  end

  defp transient_error(socket, reason, message) do
    if socket.assigns.page_result.ok? do
      socket
      |> clear_loading()
      |> put_flash(:error, message)
    else
      socket
      |> assign(:page_result, AsyncResult.failed(socket.assigns.page_result, reason))
      |> assign(:dirty?, false)
    end
  end

  defp clear_loading(socket) do
    socket
    |> assign(:page_result, %{socket.assigns.page_result | loading: nil})
    |> assign(:dirty?, false)
  end

  defp apply_controls(socket, params) do
    {controls, changeset} = ProcessListControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :controls))
    |> assign(:page, 1)
  end

  # `start_async/3` replaces the task but not the scan it spawned on the remote,
  # so a burst of clicks would cost the node a full scan each. The dropped
  # request is remembered instead: the assigns that asked for it are already
  # committed, so without the replay the table would keep showing rows that do
  # not match its own sort header or controls.
  defp fetch(socket, priority \\ :high) do
    if loading?(socket.assigns.page_result) do
      assign(socket, :refetch_queued?, true)
    else
      start_fetch(socket, priority)
    end
  end

  defp start_fetch(socket, priority) do
    %{session: session, controls: controls, sort_by: sort_by, direction: direction} =
      socket.assigns

    socket = assign(socket, :refetch_queued?, false)

    # The previous result stays assigned (only marked loading) while a refetch
    # runs, so the table keeps its rows and the UI can lock over them.
    socket
    |> assign(:page_result, AsyncResult.loading(socket.assigns.page_result))
    |> start_async(:page_result, fn ->
      run_fetch(priority, session.node, controls, {sort_by, direction})
    end)
  end

  defp run_fetch(priority, node, controls, sort) do
    started = System.monotonic_time(:millisecond)
    result = RateLimiter.run(priority, fn -> Processes.page(node, controls, sort) end)
    pad_to_min(started)

    case result do
      {:ok, {:ok, page}, elapsed_us} ->
        {:ok, page, controls, div(elapsed_us, 1_000)}

      {:ok, {:error, reason}, _elapsed_us} ->
        Logger.warning("Failed to list processes on #{inspect(node)}: #{inspect(reason)}")
        {:error, reason}

      {:error, :rate_limited, _retry_after_ms} when priority == :low ->
        # A skipped background refresh is not an error; the next tick retries.
        :skipped

      {:error, :rate_limited, retry_after_ms} ->
        {:rate_limited, retry_after_ms}
    end
  end

  defp pad_to_min(started) do
    elapsed = System.monotonic_time(:millisecond) - started

    if elapsed < @min_fetch_ms, do: Process.sleep(@min_fetch_ms - elapsed)
  end

  # Collapses a burst of control changes into one fetch: each change restarts
  # the window, and the fetch fires once the user pauses.
  defp debounce_refetch(socket) do
    if timer = socket.assigns.refetch_timer, do: Process.cancel_timer(timer)

    assign(socket, :refetch_timer, Process.send_after(self(), :refetch, @refetch_debounce_ms))
  end

  defp loading?(%AsyncResult{loading: loading}), do: loading != nil

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

  # A negative delay raises in `Process.send_after/3`, and zero ticks in a loop.
  defp parse_interval(value) do
    Enum.find_value(Processes.refresh_interval_options(), fn {_label, option} ->
      option == value && parse_integer(option)
    end)
  end

  defp restart_refresh_timer(socket) do
    if timer = socket.assigns.refresh_timer, do: Process.cancel_timer(timer)

    case socket.assigns.refresh_interval do
      nil -> assign(socket, :refresh_timer, nil)
      ms -> assign(socket, :refresh_timer, Process.send_after(self(), :auto_refresh, ms))
    end
  end

  # Only reached with no rows to fall back on, so unlike the flash it advises.
  defp format_error(:timeout),
    do: "Request timed out. Try a longer timeout or a smaller limit."

  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and refresh."

  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to list processes."
end
