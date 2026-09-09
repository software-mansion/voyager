defmodule VoyagerWeb.EtsTableLive do
  @moduledoc """
  Reads the contents of one ETS table, reached as `/node/:node/ets-tables/:table`.

  Nothing is read on mount: the table's metadata is, but its records cost the
  remote node a select, so they wait for the fetch button. Pages are backed by
  select continuations kept per page in assigns, so going back re-runs the
  select from the stored continuation; they are opaque remote terms bound to
  the table they came from and never reach the URL.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.EtsPeekComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsLookupControls
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.Hooks.TermTreeHook

  on_mount TermTreeHook

  @records_id "ets-records"
  @lookup_open_depth 3

  @impl true
  def mount(%{"table" => table_param}, _session, socket) do
    controls = EtsPeekControls.default()
    lookup_controls = EtsLookupControls.default()

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
      |> assign(:page, 0)
      |> assign(:pending_page, 0)
      |> assign(:conts, [nil])
      |> assign(:page_size, controls.chunk_size)
      |> assign(:truncated?, false)
      |> assign(:open_rows, MapSet.new())
      |> assign(:fetched?, false)
      |> assign(:last_updated, nil)
      |> assign(:sidebar, nil)
      |> assign(:lookup, %AsyncResult{})
      |> assign(:lookup_controls, lookup_controls)
      |> assign(:lookup_form, to_form(EtsLookupControls.changeset(lookup_controls), as: :lookup))

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
    <div
      id="ets-table-page"
      phx-hook="TableSettings"
      data-settings-key="ets-table"
      class="relative flex h-full"
    >
      <div class="min-w-2xl mx-auto flex h-full max-w-screen-2xl flex-1 flex-col gap-4 overflow-hidden p-6 sm:p-8">
        <EtsPeekComponents.header
          table_name={@table_param}
          node_name={@session.node_name}
          back_href={keep_sidebar(~p"/node/#{@session.node_name}/ets-tables", @current_url)}
        />

        <.async_result :let={info} assign={@info}>
          <:loading>
            <.loading_state id="ets-table-loading" message="Reading table metadata…" />
          </:loading>
          <:failed :let={reason}>
            <.error_state id="ets-table-error" message={format_error(reason)} />
          </:failed>

          <EtsPeekComponents.info_panel
            info={info}
            owner_href={process_path(@session.node_name, info.owner, @current_url)}
          />

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
            <.icon name="icon-circle-alert" class="text-warning size-4 shrink-0" />
            <span>This table is private, so its records cannot be read.</span>
          </div>

          <EtsPeekComponents.truncation_notice :if={@truncated?} />

          <.error_state
            :if={chunk_error(@chunk)}
            id="ets-peek-error"
            message={format_error(chunk_error(@chunk))}
          />

          <div :if={@fetched?} class="flex min-h-0 flex-1 flex-col gap-3">
            <div class="text-base-content/70 flex flex-wrap items-center gap-2 text-xs">
              <span id="ets-records-count">
                {Formatters.format_integer(length(@records))} records on this page
              </span>
              <span :if={@last_updated}>· fetched at {Formatters.format_time(@last_updated)}</span>
            </div>

            <p
              :if={@records == [] and @page == 0}
              id="ets-records-empty"
              class="text-base-content/70 text-sm"
            >
              This table is empty.
            </p>

            <EtsPeekComponents.records
              :if={@records != []}
              id={records_id()}
              records={@records}
              term_states={@term_states}
              open_rows={@open_rows}
              offset={@page * @page_size}
              lookupable?={lookupable?(info)}
              keypos={info.keypos}
            />

            <DataTableComponents.pager
              :if={@records != [] or @page > 0}
              id="ets-pager"
              page={@page + 1}
              page_size={@page_size}
              total={pager_total(@info, @conts, @page, @page_size, @records)}
              page_size_options={EtsPeekControls.chunk_size_options()}
            />
          </div>
        </.async_result>
      </div>

      <EtsPeekComponents.sidebar
        :if={@sidebar}
        key={@sidebar.key}
        lookup={@lookup}
        form={@lookup_form}
        term_states={@term_states}
        error_message={lookup_error_message(@lookup)}
      />
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"peek" => params}, socket) do
    {controls, changeset} = EtsPeekControls.apply(socket.assigns.controls, params)

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :peek))
    |> store_settings()
    |> noreply()
  end

  # The client's stored controls, empty when it has none. Only validated
  # values ever get stored, but the storage is still hand-editable.
  def handle_event("restore_settings", params, socket) when is_map(params) do
    {controls, changeset} =
      EtsPeekControls.apply(
        socket.assigns.controls,
        stored(params, ~w(chunk_size budget timeout))
      )

    {lookup_controls, lookup_changeset} =
      EtsLookupControls.apply(
        socket.assigns.lookup_controls,
        stored(
          %{"budget" => params["lookup_budget"], "timeout" => params["lookup_timeout"]},
          ~w(budget timeout)
        )
      )

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :peek))
    |> assign(:page_size, controls.chunk_size)
    |> assign(:lookup_controls, lookup_controls)
    |> assign(:lookup_form, to_form(lookup_changeset, as: :lookup))
    |> noreply()
  end

  def handle_event("restore_settings", _params, socket), do: noreply(socket)

  # A new snapshot starts a fresh select: the old continuations belong to a
  # walk that is no longer on screen.
  def handle_event("fetch", _params, socket) do
    socket
    |> assign(:conts, [nil])
    |> assign(:page_size, socket.assigns.controls.chunk_size)
    |> fetch_page(0)
    |> noreply()
  end

  # The pager is 1-based; a page is reachable only while its continuation is
  # stored, so a jump past the walked prefix is ignored.
  def handle_event("paginate", %{"page" => page}, socket) do
    with {page, ""} <- Integer.parse(page),
         index = page - 1,
         true <- index >= 0 and index < length(socket.assigns.conts) do
      fetch_page(socket, index)
    else
      _other -> socket
    end
    |> noreply()
  end

  # Continuations carry the limit they were created with, so a new page size
  # restarts the walk from the beginning.
  def handle_event("set_page_size", %{"page_size" => size}, socket) do
    {controls, changeset} =
      EtsPeekControls.apply(socket.assigns.controls, %{"chunk_size" => size})

    socket
    |> assign(:controls, controls)
    |> assign(:form, to_form(changeset, as: :peek))
    |> assign(:conts, [nil])
    |> assign(:page_size, controls.chunk_size)
    |> store_settings()
    |> fetch_page(0)
    |> noreply()
  end

  def handle_event("toggle_row", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} ->
        open_rows = socket.assigns.open_rows

        open_rows =
          if MapSet.member?(open_rows, index),
            do: MapSet.delete(open_rows, index),
            else: MapSet.put(open_rows, index)

        assign(socket, :open_rows, open_rows)

      _other ->
        socket
    end
    |> noreply()
  end

  def handle_event("open_sidebar", %{"index" => index}, socket) do
    with {index, ""} <- Integer.parse(index),
         record when record != nil <- Enum.at(socket.assigns.records, index),
         {:ok, key} <- EtsPeekComponents.lookup_key(record, keypos(socket)) do
      socket
      |> assign(:sidebar, %{key: key})
      |> start_lookup()
    else
      _other -> socket
    end
    |> noreply()
  end

  def handle_event("close-details-panel", _params, socket) do
    socket
    |> assign(:sidebar, nil)
    |> assign(:lookup, %AsyncResult{})
    |> noreply()
  end

  def handle_event("validate_lookup", %{"lookup" => params}, socket) do
    {controls, changeset} = EtsLookupControls.apply(socket.assigns.lookup_controls, params)

    socket
    |> assign(:lookup_controls, controls)
    |> assign(:lookup_form, to_form(changeset, as: :lookup))
    |> store_settings()
    |> noreply()
  end

  def handle_event("refetch_lookup", _params, socket) do
    case socket.assigns.sidebar do
      nil -> noreply(socket)
      _sidebar -> socket |> start_lookup() |> noreply()
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
    page = socket.assigns.pending_page
    conts = Enum.take(socket.assigns.conts, page + 1)
    conts = if chunk.continuation, do: conts ++ [chunk.continuation], else: conts

    socket
    |> assign(:chunk, AsyncResult.ok(socket.assigns.chunk, :loaded))
    |> assign(:records, chunk.records)
    |> assign(:page, page)
    |> assign(:conts, conts)
    |> assign(:truncated?, chunk.truncated?)
    |> assign(:open_rows, MapSet.new())
    |> assign(:fetched?, true)
    |> assign(:last_updated, DateTime.utc_now())
    |> put_record_terms(chunk.records)
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

  def handle_async(:lookup, {:ok, {:ok, chunk}}, socket) do
    socket =
      chunk.records
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {record, index}, acc ->
        TermTreeHook.put_term(acc, EtsPeekComponents.lookup_inspector_id(index), record,
          depth: @lookup_open_depth,
          open_all: true
        )
      end)

    socket
    |> assign(:lookup, AsyncResult.ok(socket.assigns.lookup, chunk))
    |> noreply()
  end

  def handle_async(:lookup, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:lookup, AsyncResult.failed(socket.assigns.lookup, reason))
    |> noreply()
  end

  def handle_async(:lookup, {:exit, reason}, socket) do
    socket
    |> assign(:lookup, AsyncResult.failed(socket.assigns.lookup, reason))
    |> noreply()
  end

  defp resolve_table(socket) do
    node = socket.assigns.session.node
    param = socket.assigns.table_param
    timeout = socket.assigns.controls.timeout

    start_async(socket, :info, fn ->
      with {:ok, ids} <- table_ids(node, param, timeout),
           {:ok, id} <- TableId.resolve(node, param, ids, timeout) do
        Remote.info(node, id, timeout)
      end
    end)
  end

  # A reference cannot be reconstructed from its inspect string, so it is
  # matched against the node's live table handles instead.
  defp table_ids(node, "#Ref" <> _param, timeout) do
    case Erpc.safe_call(node, :ets, :all, [], timeout) do
      {:ok, ids} when is_list(ids) -> {:ok, ids}
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp table_ids(_node, _param, _timeout), do: {:ok, []}

  defp fetch_page(socket, page) do
    node = socket.assigns.session.node
    table = socket.assigns.table_id
    limit = socket.assigns.page_size
    %{budget: budget, timeout: timeout} = socket.assigns.controls
    continuation = Enum.at(socket.assigns.conts, page)

    socket
    |> cancel_async(:chunk, {:shutdown, :cancel})
    |> assign(:pending_page, page)
    |> assign(:chunk, AsyncResult.loading(socket.assigns.chunk))
    |> start_async(:chunk, fn ->
      Fetch.select_chunk(node, table, limit, budget, continuation, timeout)
    end)
  end

  defp start_lookup(socket) do
    node = socket.assigns.session.node
    table = socket.assigns.table_id
    key = socket.assigns.sidebar.key
    %{budget: budget, timeout: timeout} = socket.assigns.lookup_controls

    socket
    |> cancel_async(:lookup, {:shutdown, :cancel})
    |> assign(:lookup, AsyncResult.loading(socket.assigns.lookup))
    |> start_async(:lookup, fn ->
      Fetch.lookup(node, table, key, budget, timeout)
    end)
  end

  # One inspector per row index, so a reloaded page reuses the ids the previous
  # one had and `:term_states` does not grow with every fetch.
  defp put_record_terms(socket, records) do
    records
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {record, index}, acc ->
      TermTreeHook.put_term(
        acc,
        EtsPeekComponents.record_inspector_id(@records_id, index),
        record
      )
    end)
  end

  defp stored(params, keys) do
    params |> Map.take(keys) |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp store_settings(socket) do
    %{controls: controls, lookup_controls: lookup_controls} = socket.assigns

    push_event(socket, "store-settings", %{
      settings: %{
        "chunk_size" => to_string(controls.chunk_size),
        "budget" => to_string(controls.budget),
        "timeout" => to_string(controls.timeout),
        "lookup_budget" => to_string(lookup_controls.budget),
        "lookup_timeout" => to_string(lookup_controls.timeout)
      }
    })
  end

  defp records_id, do: @records_id

  defp process_path(node_name, pid, current_url) do
    keep_sidebar(~p"/node/#{node_name}/processes/#{Formatters.format_pid(pid)}", current_url)
  end

  defp keypos(socket) do
    case socket.assigns.info do
      %AsyncResult{ok?: true, result: %{keypos: keypos}} -> keypos
      _info -> 1
    end
  end

  defp lookupable?(%{type: type}), do: type in [:set, :ordered_set]

  # The metadata size is only an estimate once paging starts: with no
  # continuation left the walked count is exact, otherwise the total must at
  # least keep the next page reachable. A table that shrank mid-walk can end
  # on an empty page, so the current page stays addressable or Previous
  # disappears with it.
  defp pager_total(info, conts, page, page_size, records) do
    cond do
      length(conts) > page + 1 -> max(info_size(info), (page + 1) * page_size + 1)
      page > 0 -> max(page * page_size + length(records), page * page_size + 1)
      true -> length(records)
    end
  end

  defp info_size(%AsyncResult{ok?: true, result: %{size: size}}), do: size
  defp info_size(_info), do: 0

  defp readable?(%AsyncResult{ok?: true, result: %{protection: :private}}), do: false
  defp readable?(%AsyncResult{ok?: true}), do: true
  defp readable?(_info), do: false

  defp loading?(%AsyncResult{loading: loading}), do: loading != nil

  defp chunk_error(%AsyncResult{failed: false}), do: nil
  defp chunk_error(%AsyncResult{failed: reason}), do: reason

  defp lookup_error_message(%AsyncResult{failed: false}), do: nil
  defp lookup_error_message(%AsyncResult{failed: reason}), do: format_error(reason)

  defp format_error(:not_found), do: "No such table on this node."
  defp format_error(:invalid_name), do: "That is not a usable table name."
  defp format_error(:cannot_read), do: "This table cannot be read."
  defp format_error(:invalid_limit), do: "That page size is not allowed."

  # The agent worker is killed by its heap cap; erpc reports that as an exit.
  defp format_error({:remote_exit, {:signal, :killed}}),
    do: "A record was too large to read. Try a smaller page size."

  defp format_error(:timeout), do: "Request timed out. Try a longer timeout or a smaller page."
  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and try again."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to read the table."
end
