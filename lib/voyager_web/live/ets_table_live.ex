defmodule VoyagerWeb.EtsTableLive do
  @moduledoc """
  Reads the contents of one ETS table, reached as `/node/:node/ets-tables/:table`.

  Nothing is read on mount: the table's metadata is, but its records cost the
  remote node a select, so they wait for the fetch button. The continuation is
  an opaque remote term kept in assigns and bound to the table it came from, so
  it never reaches the URL and can never be replayed against another table.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Components.EtsPeekComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.Hooks.TermTreeHook

  on_mount TermTreeHook

  @records_id "ets-records"

  @impl true
  def mount(%{"table" => table_param}, _session, socket) do
    controls = EtsPeekControls.default()

    socket =
      socket
      |> assign(:active_nav, :ets_tables)
      |> assign(:table_param, table_param)
      |> assign(:table_id, nil)
      |> assign(:info, AsyncResult.loading())
      |> assign(:controls, controls)
      |> assign(:form, to_form(EtsPeekControls.changeset(controls), as: :peek))
      |> assign(:chunk, %AsyncResult{})
      |> assign(:records, [])
      |> assign(:continuation, nil)
      |> assign(:fetched?, false)
      |> assign(:last_updated, nil)

    if connected?(socket) do
      resolve_table(socket)
    else
      socket
    end
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col gap-4 overflow-y-auto p-6 sm:p-8">
      <EtsPeekComponents.header
        table_name={@table_param}
        node_name={@session.node_name}
        info={table_info(@info)}
      />

      <.async_result :let={_info} assign={@info}>
        <:loading>
          <.loading_state id="ets-table-loading" message="Reading table metadata…" />
        </:loading>
        <:failed :let={reason}>
          <.error_state id="ets-table-error" message={format_error(reason)} />
        </:failed>

        <EtsPeekComponents.controls
          form={@form}
          loading?={loading?(@chunk)}
          readable?={readable?(@info)}
          fetched?={@fetched?}
        />

        <div
          :if={not readable?(@info)}
          id="ets-private-notice"
          role="note"
          class="alert alert-warning text-xs"
        >
          <.icon name="icon-circle-alert" class="size-4 shrink-0" />
          <span>This table is private, so its records cannot be read.</span>
        </div>

        <EtsPeekComponents.truncation_notice :if={@fetched?} />

        <.error_state
          :if={chunk_error(@chunk)}
          id="ets-peek-error"
          message={format_error(chunk_error(@chunk))}
        />

        <div :if={@fetched?} class="flex flex-col gap-3">
          <div class="text-base-content/70 flex flex-wrap items-center gap-2 text-xs">
            <span id="ets-records-count">
              {Formatters.format_integer(length(@records))} records shown
            </span>
            <span :if={@last_updated}>· fetched at {Formatters.format_time(@last_updated)}</span>
          </div>

          <p :if={@records == []} id="ets-records-empty" class="text-base-content/70 text-sm">
            This table is empty.
          </p>

          <EtsPeekComponents.records
            :if={@records != []}
            id={records_id()}
            records={@records}
            term_states={@term_states}
          />

          <button
            :if={@continuation}
            id="ets-peek-more"
            type="button"
            phx-click="fetch_more"
            disabled={loading?(@chunk)}
            class="btn btn-outline btn-sm w-fit gap-2"
          >
            <span :if={loading?(@chunk)} class="loading loading-spinner loading-xs" /> Load more
          </button>

          <p :if={is_nil(@continuation) and @records != []} class="text-base-content/50 text-xs">
            End of table.
          </p>
        </div>
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"peek" => params}, socket) do
    {controls, changeset} = EtsPeekControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :peek))
    |> noreply()
  end

  # A new snapshot starts a fresh select: the old continuation belongs to a
  # walk that is no longer on screen.
  def handle_event("fetch", _params, socket) do
    socket
    |> assign(:records, [])
    |> assign(:continuation, nil)
    |> start_fetch(nil)
    |> noreply()
  end

  def handle_event("fetch_more", _params, socket) do
    case socket.assigns.continuation do
      nil -> noreply(socket)
      continuation -> socket |> start_fetch(continuation) |> noreply()
    end
  end

  @impl true
  def handle_async(:info, {:ok, {:ok, info}}, socket) do
    socket
    |> assign(:table_id, info.id)
    |> assign(:info, AsyncResult.ok(socket.assigns.info, info))
    |> noreply()
  end

  def handle_async(:info, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:info, AsyncResult.failed(socket.assigns.info, reason))
    |> noreply()
  end

  def handle_async(:info, {:exit, reason}, socket) do
    socket
    |> assign(:info, AsyncResult.failed(socket.assigns.info, reason))
    |> noreply()
  end

  def handle_async(:chunk, {:ok, {:ok, chunk}}, socket) do
    offset = length(socket.assigns.records)
    records = socket.assigns.records ++ chunk.records

    socket
    |> assign(:chunk, AsyncResult.ok(socket.assigns.chunk, :loaded))
    |> assign(:records, records)
    |> assign(:continuation, chunk.continuation)
    |> assign(:fetched?, true)
    |> assign(:last_updated, DateTime.utc_now())
    |> put_record_terms(chunk.records, offset)
    |> noreply()
  end

  def handle_async(:chunk, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:chunk, AsyncResult.failed(socket.assigns.chunk, reason))
    |> noreply()
  end

  def handle_async(:chunk, {:exit, reason}, socket) do
    socket
    |> assign(:chunk, AsyncResult.failed(socket.assigns.chunk, reason))
    |> noreply()
  end

  defp resolve_table(socket) do
    node = socket.assigns.session.node
    param = socket.assigns.table_param
    timeout = socket.assigns.controls.timeout

    start_async(socket, :info, fn ->
      with {:ok, id} <- TableId.resolve(node, param, [], timeout) do
        Remote.info(node, id, timeout)
      end
    end)
  end

  defp start_fetch(socket, continuation) do
    node = socket.assigns.session.node
    table = socket.assigns.table_id
    %{chunk_size: chunk_size, timeout: timeout} = socket.assigns.controls

    socket
    |> assign(:chunk, AsyncResult.loading(socket.assigns.chunk))
    |> start_async(:chunk, fn ->
      Fetch.select_chunk(node, table, chunk_size, continuation, timeout)
    end)
  end

  # One inspector per row index, so a reloaded snapshot reuses the ids the
  # previous one had and `:term_states` does not grow with every fetch.
  defp put_record_terms(socket, records, offset) do
    records
    |> Enum.with_index(offset)
    |> Enum.reduce(socket, fn {record, index}, acc ->
      TermTreeHook.put_term(
        acc,
        EtsPeekComponents.record_inspector_id(@records_id, index),
        record
      )
    end)
  end

  defp records_id, do: @records_id

  defp table_info(%AsyncResult{ok?: true, result: info}), do: info
  defp table_info(_info), do: nil

  defp readable?(%AsyncResult{ok?: true, result: %{protection: :private}}), do: false
  defp readable?(%AsyncResult{ok?: true}), do: true
  defp readable?(_info), do: false

  defp loading?(%AsyncResult{loading: loading}), do: loading != nil

  defp chunk_error(%AsyncResult{failed: false}), do: nil
  defp chunk_error(%AsyncResult{failed: reason}), do: reason

  defp format_error(:not_found), do: "No such table on this node."
  defp format_error(:invalid_name), do: "That is not a usable table name."
  defp format_error(:cannot_read), do: "This table cannot be read."
  defp format_error(:invalid_limit), do: "That chunk size is not allowed."

  defp format_error(:heap_limit_exceeded),
    do: "A record was too large to read. Try a smaller chunk size."

  defp format_error(:timeout), do: "Request timed out. Try a longer timeout or a smaller chunk."
  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and try again."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to read the table."
end
