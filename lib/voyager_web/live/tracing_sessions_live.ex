defmodule VoyagerWeb.TracingSessionsLive do
  @moduledoc """
  Landing page for Tracing (`/node/:node/tracing`): lists the active tracing
  session pinned above paginated saved history, with a node filter and an
  overview of the selected session.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias Voyager.Services.Tracer.Writer
  alias VoyagerWeb.Components.TracingBrowserComponents
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TracingStatusHook
  alias VoyagerWeb.Utils.URL

  @page_size 20
  @tick_ms 1_000
  @actions [:create, :stop, :unload, :load, :copy, :delete]
  # SQLite raises on an integer bind past int64.
  @max_row_id 0x7FFFFFFFFFFFFFFF

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :tracing)
      |> assign(:loaded?, false)
      |> assign(:pending, nil)
      |> assign(:confirm, nil)
      |> assign(:active_session, nil)
      |> assign(:queued_active, nil)
      |> assign(:flush_scheduled?, false)
      |> assign(:tick_scheduled?, false)
      |> assign(:node_filter, nil)
      |> assign(:node_counts, %{})
      |> assign(:total_history, 0)
      |> assign(:shown_history_count, 0)
      |> assign(:history_empty?, true)
      |> assign(:has_more?, false)
      |> assign(:oldest_id, nil)
      |> assign(:history_by_id, %{})
      |> assign(:extra_selected, nil)
      |> assign(:selected_id, nil)
      |> assign(:selected_param, nil)
      |> assign(:overview, AsyncResult.ok(nil))
      |> assign(:used_bytes, 0)
      |> assign(:storage_limit_mb, Tracer.storage_limit_mb())
      |> assign(:now, DateTime.utc_now())
      |> TracingStatusHook.defer_puts()
      |> stream(:history, [])

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())

        # Tracer.active/0 queues behind a run's start and Writer.flush/0 behind pending writes.
        start_async(socket, :initial_load, fn ->
          active = Tracer.active()
          Writer.flush()
          active
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    query = URI.decode_query(URI.parse(uri).query || "")
    next_filter = parse_node_filter(query, socket.assigns.session.node_name)
    selected_param = parse_selected_id(query)
    filter_changed? = next_filter != socket.assigns.node_filter

    socket =
      socket
      |> assign(:node_filter, next_filter)
      |> assign(:selected_param, selected_param)

    if connected?(socket) and socket.assigns.loaded? do
      socket = if filter_changed?, do: reload_history(socket), else: resolve_selection(socket)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    selected = selected_item(assigns)
    selected_active? = match?(%Session{}, selected)

    assigns =
      assign(assigns,
        selected_item: selected,
        selected_active?: selected_active?,
        busy?: match?(%Session{status: :running}, assigns.active_session),
        displayed_count: displayed_count(assigns),
        hidden_count: hidden_count(assigns),
        runtime_seconds: item_runtime_seconds(selected, assigns.overview.result, assigns.now)
      )

    ~H"""
    <div
      id="tracing-sessions-page"
      class="mx-auto flex h-full max-w-screen-2xl gap-4 p-6 sm:p-8"
    >
      <div :if={!@loaded?} class="flex-1">
        <.loading_state id="sessions-loading" message="Loading sessions…" />
      </div>
      <section
        :if={@loaded?}
        id="sessions-list-card"
        class="card bg-base-100 border-base-200 min-w-64 flex w-1/3 max-w-md flex-none flex-col border shadow-sm"
      >
        <div class="border-base-200 flex flex-col gap-3 border-b px-5 py-4">
          <TracingBrowserComponents.list_header
            count={@displayed_count}
            busy?={@busy?}
            pending?={@pending != nil}
            on_create="create-session"
          />
          <TracingBrowserComponents.node_filter_bar
            node_filter={@node_filter}
            connected_node={@session.node_name}
            node_counts={@node_counts}
            total_history={@total_history}
            on_filter="filter-node"
          />
        </div>

        <div id="tiles" class="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto p-3">
          <TracingBrowserComponents.session_tile
            :if={@active_session}
            id="active-session-tile"
            item={@active_session}
            active?
            selected?={@selected_id == @active_session.id}
            connected_node={@session.node_name}
            now={@now}
            on_select="select-session"
          />
          <div class="font-mono tracking-label text-base-content/60 px-3.5 pt-3 pb-1 text-xs font-semibold uppercase">
            History
          </div>
          <TracingBrowserComponents.empty_tiles
            :if={@history_empty?}
            hidden_count={@hidden_count}
            node_filter={@node_filter}
            connected_node={@session.node_name}
            on_filter="filter-node"
          />
          <div id="history-tiles" phx-update="stream" class="flex flex-col gap-1.5">
            <TracingBrowserComponents.session_tile
              :for={{dom_id, row} <- @streams.history}
              id={dom_id}
              item={row}
              selected?={@selected_id == row.id}
              connected_node={@session.node_name}
              now={@now}
              on_select="select-session"
            />
          </div>
          <button
            :if={@has_more?}
            type="button"
            id="show-older"
            phx-click="show-older"
            class="btn btn-ghost btn-sm text-base-content/70 mt-1 w-full"
          >
            Show older
          </button>
        </div>

        <TracingBrowserComponents.storage_footer
          used_bytes={@used_bytes}
          limit_mb={@storage_limit_mb}
        />
      </section>

      <section
        :if={@loaded?}
        id="overview"
        class="@container/overview flex min-w-0 flex-1 flex-col gap-4 overflow-y-auto"
      >
        <TracingBrowserComponents.no_selection_state :if={is_nil(@selected_item)} />
        <TracingBrowserComponents.overview_session_card
          :if={@selected_item}
          item={@selected_item}
          active?={@selected_active?}
          busy?={@busy?}
          pending?={@pending != nil}
          connected_node={@session.node_name}
          runtime_seconds={@runtime_seconds}
          storage_limit_mb={@storage_limit_mb}
          open_href={session_path(@session, @selected_item.id)}
          on_stop="stop-session"
          on_unload="unload-session"
          on_load="load-session"
          on_copy="copy-session"
          on_delete="delete-session"
        />
        <TracingBrowserComponents.idle_overview_state :if={
          @selected_item != nil and @selected_item.status == :idle
        } />
        <.async_result
          :let={overview}
          :if={@selected_item != nil and @selected_item.status != :idle}
          assign={@overview}
        >
          <:loading>
            <.loading_state id="overview-loading" message="Loading session overview…" />
          </:loading>
          <:failed>
            <.error_state id="overview-error" message="Could not load session overview." />
          </:failed>
          <TracingBrowserComponents.overview_charts
            :if={overview}
            item={@selected_item}
            overview={overview}
          />
        </.async_result>
      </section>

      <.browser_confirm_modal
        :if={@confirm}
        confirm={@confirm}
        active_session={@active_session}
        selected_item={@selected_item}
      />
    </div>
    """
  end

  attr :confirm, :any, required: true
  attr :active_session, Session, default: nil
  attr :selected_item, :map, default: nil

  defp browser_confirm_modal(assigns) do
    kind = confirm_kind(assigns.confirm)
    assigns = assign(assigns, kind: kind, save_choice?: kind in [:create, :copy])

    ~H"""
    <TracingComponents.confirm_modal
      id={"#{@kind}-session-modal"}
      title={confirm_title(@kind)}
      confirm_label={confirm_label(@kind)}
      confirm_class={confirm_class(@kind)}
      cancel_label={if @save_choice?, do: "No", else: "Cancel"}
      on_confirm={
        if @save_choice?,
          do: JS.push("confirm-action", value: %{save: true}),
          else: "confirm-action"
      }
      on_cancel={
        if @save_choice?,
          do: JS.push("confirm-action", value: %{save: false}),
          else: "cancel-confirm"
      }
      on_dismiss="cancel-confirm"
    >
      <p :if={@kind == :stop and @active_session != nil} class="text-base-content/70 mt-1 text-sm">
        Tracing <span class="font-mono">{TracingComponents.traced_mfa(@active_session.config)}</span>
        on <span class="font-mono">{@active_session.node}</span>
        stops. Its {Formatters.format_integer(@active_session.traces)} traces {if @active_session.save,
          do: "stay saved",
          else: "are kept"}, and you can resume it from the session page.
      </p>
      <p :if={@kind == :delete and @selected_item != nil} class="text-base-content/70 mt-1 text-sm">
        <span :if={@selected_item.config}>
          The
          <span class="text-base-content font-mono">
            {TracingComponents.traced_mfa(@selected_item.config)}
          </span>
          session
        </span>
        <span :if={!@selected_item.config}>This session</span>
        {removed_copy(@selected_item.traces)}
      </p>
      <p :if={@kind == :unload} class="text-base-content/70 mt-1 text-sm">
        This session is not saved, so its traces are lost.
      </p>
      <p :if={@kind == :load} class="text-base-content/70 mt-1 text-sm">
        Loading discards the unsaved active session.
      </p>
      <p :if={@save_choice?} class="text-base-content/70 mt-1 text-sm">
        A saved session is stored on disk with all its traces and stays in History. An unsaved one keeps only the newest {Tracer.kept_traces()} traces in memory and is gone once unloaded.
      </p>
      <p
        :if={@save_choice? and unsaved_active?(@active_session)}
        id="replace-unsaved-warning"
        class="text-warning mt-2 text-sm"
      >
        The active session is not saved. Creating a new one discards it.
      </p>
    </TracingComponents.confirm_modal>
    """
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{loaded?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("filter-node", %{"node" => node}, socket) do
    connected = socket.assigns.session.node_name

    url =
      socket.assigns.current_url
      |> drop_or_put("node", if(node == connected, do: nil, else: node))
      |> URL.drop_query_param("session")

    socket
    |> push_patch(to: url)
    |> noreply()
  end

  def handle_event("select-session", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {_id, ""} ->
        socket
        |> push_patch(to: URL.put_query_param(socket.assigns.current_url, "session", raw_id))
        |> noreply()

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("show-older", _params, %{assigns: %{has_more?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("show-older", _params, socket) do
    %{node_filter: node_filter, active_session: active, oldest_id: oldest_id} = socket.assigns

    page =
      TraceSessionQueries.page(
        before_id: oldest_id,
        limit: @page_size,
        node: query_node(node_filter),
        exclude_id: active && active.id
      )

    new_map = Map.new(page.rows, &{&1.id, &1})

    socket
    |> update(:history_by_id, &Map.merge(&1, new_map))
    |> assign(:has_more?, page.has_more?)
    |> assign(:oldest_id, List.last(page.rows, %{id: oldest_id}).id)
    |> stream(:history, page.rows)
    |> noreply()
  end

  def handle_event("create-session", _params, socket) do
    socket
    |> assign(:confirm, :create)
    |> noreply()
  end

  def handle_event("stop-session", _params, socket) do
    socket
    |> assign(:confirm, :stop)
    |> noreply()
  end

  def handle_event("unload-session", _params, socket) do
    socket
    |> confirm_or_run(:unload)
    |> noreply()
  end

  def handle_event("load-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{id: id} = item when not is_struct(item, Session) and id > 0 ->
        socket
        |> confirm_or_run({:load, id})
        |> noreply()

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("copy-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{status: status, config: config} = item when status != :running ->
        other_node? =
          TracingBrowserComponents.other_node?(item, socket.assigns.session.node_name)

        socket
        |> assign(:confirm, {:copy, {config, other_node?}})
        |> noreply()

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("delete-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{id: id, status: status} when id > 0 and status != :running ->
        socket
        |> assign(:confirm, {:delete, id})
        |> noreply()

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel-confirm", _params, socket) do
    socket
    |> assign(:confirm, nil)
    |> noreply()
  end

  def handle_event("confirm-action", params, socket) do
    confirm = socket.assigns.confirm
    socket = assign(socket, :confirm, nil)

    socket
    |> execute_confirmed(confirm, params["save"] == true)
    |> noreply()
  end

  @impl true
  def handle_async(:initial_load, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:initial_load, _result, %{assigns: %{loaded?: true}} = socket),
    do: {:noreply, socket}

  def handle_async(:initial_load, {:ok, active}, socket) do
    socket
    |> assign(:loaded?, true)
    |> assign(:active_session, active)
    |> reload_history()
    |> schedule_tick()
    |> noreply()
  end

  def handle_async(:initial_load, {:exit, _reason}, socket) do
    socket
    |> assign(:loaded?, true)
    |> reload_history()
    |> put_flash(:error, format_error(:exit))
    |> noreply()
  end

  def handle_async(:overview, {:ok, {id, {:ok, data}}}, socket) do
    if socket.assigns.selected_id == id do
      socket
      |> assign(:overview, AsyncResult.ok(data))
      |> noreply()
    else
      {:noreply, socket}
    end
  end

  def handle_async(:overview, {:ok, {id, {:error, :not_found}}}, socket) do
    if socket.assigns.selected_id == id do
      socket
      |> assign(:overview, AsyncResult.ok(nil))
      |> noreply()
    else
      {:noreply, socket}
    end
  end

  def handle_async(:overview, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:overview, {:exit, reason}, socket) do
    socket
    |> assign(:overview, AsyncResult.failed(%AsyncResult{}, reason))
    |> noreply()
  end

  def handle_async(name, {:ok, {:ok, %Session{id: id}}}, socket) when name in [:create, :copy] do
    socket
    |> assign(:pending, nil)
    |> push_navigate(to: session_path(socket.assigns.session, id))
    |> noreply()
  end

  def handle_async(:copy, {:ok, {:ok, %Session{id: id}, :config_dropped}}, socket) do
    socket
    |> assign(:pending, nil)
    |> put_flash(:error, "Parameters could not be copied to this node.")
    |> push_navigate(to: session_path(socket.assigns.session, id))
    |> noreply()
  end

  def handle_async(:delete, {:ok, {:ok, deleted}}, socket) do
    socket =
      if match?(%Session{id: id} when id == deleted.id, socket.assigns.active_session),
        do: apply_active_change(socket, nil),
        else: remove_deleted_row(socket, deleted.id)

    socket
    |> assign(:pending, nil)
    |> put_flash(:info, "Tracing session deleted.")
    |> noreply()
  end

  def handle_async(:load, {:ok, {:ok, %Session{id: id} = session}}, socket) do
    socket
    |> assign(:pending, nil)
    |> apply_active_change(session)
    |> update_selected_tile(id)
    |> noreply()
  end

  def handle_async(name, result, socket) when name in @actions do
    socket = assign(socket, :pending, nil)

    case result do
      {:ok, {:error, reason}} ->
        socket
        |> put_flash(:error, format_error(reason))
        |> noreply()

      {:exit, _reason} ->
        socket
        |> put_flash(:error, format_error(:exit))
        |> noreply()

      {:ok, _ok} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:session_activated, %Session{} = session}, socket) do
    socket
    |> apply_active_change(session)
    |> noreply()
  end

  def handle_info({:session_closed, _id}, socket) do
    socket
    |> apply_active_change(nil)
    |> noreply()
  end

  def handle_info(
        {:session_entries, %Session{} = session, _entries},
        %{assigns: %{loaded?: false}} = socket
      ) do
    socket
    |> apply_active_change(session)
    |> schedule_flush()
    |> noreply()
  end

  def handle_info({:session_entries, %Session{} = session, _entries}, socket) do
    socket
    |> queue_or_put_active(session)
    |> schedule_flush()
    |> noreply()
  end

  def handle_info(:flush, socket) do
    socket
    |> assign(:flush_scheduled?, false)
    |> put_queued_active()
    |> TracingStatusHook.put_queued()
    |> noreply()
  end

  def handle_info(:tick, socket) do
    socket
    |> assign(:tick_scheduled?, false)
    |> assign(:now, DateTime.utc_now())
    |> refresh_running_overview()
    |> schedule_tick()
    |> noreply()
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp execute_confirmed(socket, :create, save?),
    do: run_action(socket, :create, fn -> Tracer.create(:ui, save: save?) end)

  defp execute_confirmed(socket, {:copy, {config, other_node?}}, save?) do
    node = socket.assigns.session.node

    run_action(socket, :copy, fn ->
      with {:ok, session} <- Tracer.create(:ui, save: save?) do
        copy_config_to_node(node, config, other_node?, session)
      end
    end)
  end

  defp execute_confirmed(socket, :stop, _save?),
    do: run_action(socket, :stop, fn -> Tracer.stop(:ui) end)

  defp execute_confirmed(socket, :unload, _save?),
    do: run_action(socket, :unload, &Tracer.close/0)

  defp execute_confirmed(socket, {:load, id}, _save?),
    do: run_action(socket, :load, fn -> Tracer.load(id) end)

  defp execute_confirmed(socket, {:delete, id}, _save?),
    do: run_action(socket, :delete, fn -> Tracer.delete(id) end)

  defp execute_confirmed(socket, _nil, _save?), do: socket

  defp confirm_or_run(socket, confirm) do
    if unsaved_active?(socket.assigns.active_session),
      do: assign(socket, :confirm, confirm),
      else: execute_confirmed(socket, confirm, false)
  end

  defp copy_config_to_node(_node, nil, _other_node?, session), do: {:ok, session}

  # Pid strings resolve on any node, so another node's would select unrelated processes.
  defp copy_config_to_node(_node, %Config{processes: :pids}, true, session),
    do: {:ok, session, :config_dropped}

  defp copy_config_to_node(node, %Config{} = config, _other_node?, session) do
    case Tracer.configure(node, Map.from_struct(config), :ui) do
      {:ok, configured} -> {:ok, configured}
      {:error, %Ecto.Changeset{}} -> {:ok, session, :config_dropped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_action(socket, name, fun) do
    socket
    |> assign(:pending, name)
    |> start_async(name, fun)
  end

  defp apply_active_change(socket, next_active) do
    prev_active = socket.assigns.active_session

    select =
      if socket.assigns.loaded?,
        do: &adjust_selection_after_active_change(&1, prev_active, next_active),
        else: &resolve_selection/1

    socket
    |> cancel_async(:initial_load)
    |> assign(:loaded?, true)
    |> assign(:active_session, next_active)
    |> assign(:queued_active, nil)
    |> drop_stale_confirm(next_active)
    |> reload_history(select)
    |> schedule_tick()
  end

  defp adjust_selection_after_active_change(socket, _prev, %Session{id: next_id})
       when is_nil(socket.assigns.selected_id),
       do: update_selected_tile(socket, next_id)

  defp adjust_selection_after_active_change(socket, %Session{id: prev_id}, %Session{id: next_id})
       when socket.assigns.selected_id == prev_id and prev_id != next_id,
       do: update_selected_tile(socket, next_id)

  defp adjust_selection_after_active_change(socket, %Session{id: prev_id}, nil)
       when socket.assigns.selected_id == prev_id do
    if Map.has_key?(socket.assigns.history_by_id, prev_id),
      do: socket,
      else: resolve_selection(socket)
  end

  defp adjust_selection_after_active_change(socket, _prev, _next), do: resolve_selection(socket)

  defp queue_or_put_active(
         %{assigns: %{active_session: %Session{id: id, status: status, config: config}}} = socket,
         %Session{id: id, status: status, config: config} = session
       ) do
    assign(socket, :queued_active, session)
  end

  defp queue_or_put_active(socket, %Session{} = session) do
    socket =
      socket
      |> assign(:active_session, session)
      |> assign(:queued_active, nil)
      |> assign(:used_bytes, TraceSessionQueries.bytes_except(0))
      |> drop_stale_confirm(session)
      |> schedule_tick()

    if socket.assigns.selected_id == session.id,
      do: fetch_overview(socket),
      else: socket
  end

  defp put_queued_active(%{assigns: %{queued_active: nil}} = socket), do: socket

  defp put_queued_active(socket) do
    session = socket.assigns.queued_active
    other_bytes = TraceSessionQueries.bytes_except(session.id)

    socket
    |> assign(:active_session, session)
    |> assign(:queued_active, nil)
    |> assign(:used_bytes, other_bytes + if(session.save, do: session.bytes, else: 0))
  end

  defp schedule_flush(%{assigns: %{flush_scheduled?: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush, TracingStatusHook.throttle_ms())
    assign(socket, :flush_scheduled?, true)
  end

  defp schedule_tick(
         %{assigns: %{tick_scheduled?: false, active_session: %Session{status: :running}}} =
           socket
       ) do
    Process.send_after(self(), :tick, @tick_ms)
    assign(socket, :tick_scheduled?, true)
  end

  defp schedule_tick(socket), do: socket

  defp drop_stale_confirm(%{assigns: %{confirm: :stop}} = socket, active) do
    if match?(%Session{status: :running}, active),
      do: socket,
      else: assign(socket, :confirm, nil)
  end

  defp drop_stale_confirm(%{assigns: %{confirm: {:delete, id}}} = socket, %Session{
         id: id,
         status: :running
       }),
       do: assign(socket, :confirm, nil)

  defp drop_stale_confirm(socket, _active), do: socket

  defp remove_deleted_row(socket, id) do
    {removed, by_id} = Map.pop(socket.assigns.history_by_id, id)

    selected? = socket.assigns.selected_id == id
    socket = if selected?, do: assign(socket, :selected_param, nil), else: socket
    select = if selected?, do: &resolve_selection/1, else: & &1

    if map_size(by_id) == 0 do
      reload_history(socket, select)
    else
      socket =
        socket
        |> assign(:history_by_id, by_id)
        |> assign(:oldest_id, by_id |> Map.keys() |> Enum.min())
        |> refresh_history_counts()

      socket =
        if removed,
          do: stream_delete(socket, :history, removed),
          else: socket

      socket
      |> assign(:has_more?, map_size(by_id) < socket.assigns.shown_history_count)
      |> select.()
    end
  end

  # LiveStream renders an id at its latest insert, so a tile re-inserted after the reset sinks to the end.
  defp reload_history(socket, select \\ &resolve_selection/1) do
    %{node_filter: node_filter, active_session: active} = socket.assigns
    exclude_id = active && active.id

    page =
      TraceSessionQueries.page(
        limit: @page_size,
        node: query_node(node_filter),
        exclude_id: exclude_id
      )

    socket
    |> refresh_history_counts()
    |> assign(:history_empty?, page.rows == [])
    |> assign(:has_more?, page.has_more?)
    |> assign(:oldest_id, List.last(page.rows, %{id: nil}).id)
    |> assign(:history_by_id, Map.new(page.rows, &{&1.id, &1}))
    |> assign(:now, DateTime.utc_now())
    |> select.()
    |> stream(:history, page.rows, reset: true)
  end

  defp refresh_history_counts(socket) do
    %{node_filter: node_filter, active_session: active} = socket.assigns
    exclude_id = active && active.id
    node_counts = TraceSessionQueries.counts_by_node(exclude_id)
    total_history = TraceSessionQueries.total_count(exclude_id)
    used_bytes = TraceSessionQueries.bytes_except(0)

    shown_history =
      if node_filter == "all",
        do: total_history,
        else: Map.get(node_counts, node_filter, 0)

    socket
    |> assign(:node_counts, node_counts)
    |> assign(:total_history, total_history)
    |> assign(:shown_history_count, shown_history)
    |> assign(:used_bytes, used_bytes)
  end

  defp resolve_selection(socket) do
    %{
      selected_param: param_id,
      active_session: active,
      history_by_id: by_id,
      node_filter: node_filter
    } = socket.assigns

    {id, extra_row} = target_selection(param_id, active, by_id, node_filter)

    socket
    |> assign(:extra_selected, extra_row)
    |> update_selected_tile(id)
  end

  defp target_selection(nil, active, by_id, _node_filter),
    do: {default_selected_id(active, by_id), nil}

  defp target_selection(id, %Session{id: id}, _by_id, _node_filter), do: {id, nil}

  defp target_selection(id, active, by_id, node_filter) do
    cond do
      Map.has_key?(by_id, id) ->
        {id, nil}

      id > 0 ->
        case TraceSessionQueries.find_listed(id, node_filter) do
          nil -> {default_selected_id(active, by_id), nil}
          row -> {row.id, row}
        end

      true ->
        {default_selected_id(active, by_id), nil}
    end
  end

  defp update_selected_tile(%{assigns: %{selected_id: id}} = socket, id), do: socket

  defp update_selected_tile(socket, next_id) do
    prev_id = socket.assigns.selected_id
    by_id = socket.assigns.history_by_id

    socket =
      socket
      |> assign(:selected_id, next_id)
      |> drop_selected_item_confirm()

    Enum.reduce([prev_id, next_id], socket, fn id, acc ->
      if row = by_id[id], do: stream_insert(acc, :history, row), else: acc
    end)
    |> assign(:overview, AsyncResult.ok(nil))
    |> fetch_overview()
  end

  defp drop_selected_item_confirm(%{assigns: %{confirm: {_kind, _item}}} = socket),
    do: assign(socket, :confirm, nil)

  defp drop_selected_item_confirm(socket), do: socket

  defp fetch_overview(socket) do
    case selected_item(socket.assigns) do
      %{status: status, id: id} when status != :idle ->
        socket
        |> cancel_async(:overview)
        |> assign(:overview, loading_overview(socket.assigns.overview))
        |> start_async(:overview, fn -> {id, Tracer.overview(id)} end)

      _none_or_idle ->
        socket
        |> cancel_async(:overview)
        |> assign(:overview, AsyncResult.ok(nil))
    end
  end

  defp loading_overview(%AsyncResult{result: %{} = data}),
    do: AsyncResult.loading(AsyncResult.ok(data))

  defp loading_overview(_overview), do: AsyncResult.loading()

  defp refresh_running_overview(
         %{
           assigns: %{
             selected_id: id,
             active_session: %Session{id: id, status: :running},
             overview: %{loading: nil}
           }
         } = socket
       ),
       do: fetch_overview(socket)

  defp refresh_running_overview(socket), do: socket

  defp default_selected_id(%Session{id: id}, _by_id), do: id

  defp default_selected_id(nil, by_id) do
    by_id
    |> Map.keys()
    |> Enum.max(fn -> nil end)
  end

  defp selected_item(%{selected_id: nil}), do: nil
  defp selected_item(%{selected_id: id, active_session: %Session{id: id} = active}), do: active

  defp selected_item(%{selected_id: id, history_by_id: by_id}) when is_map_key(by_id, id),
    do: by_id[id]

  defp selected_item(%{selected_id: id, extra_selected: %{id: id} = extra}), do: extra
  defp selected_item(_assigns), do: nil

  defp item_runtime_seconds(nil, _overview, _now), do: 0

  defp item_runtime_seconds(item, %{runs: [_ | _] = runs}, now) do
    total_ms =
      Enum.reduce(runs, 0, fn run, acc ->
        ms =
          if run.reason == :running and match?(%Session{status: :running}, item),
            do: max(DateTime.diff(now, run.started_at, :millisecond), 0),
            else: run.duration_ms

        acc + ms
      end)

    div(total_ms, 1_000)
  end

  defp item_runtime_seconds(%{started_at: nil}, _overview, _now), do: 0

  defp item_runtime_seconds(
         %Session{status: :running, run_started_at: %DateTime{} = at},
         _overview,
         now
       ),
       do: max(DateTime.diff(now, at, :second), 0)

  defp item_runtime_seconds(
         %{started_at: %DateTime{} = from, stopped_at: %DateTime{} = to},
         _overview,
         _now
       ),
       do: max(DateTime.diff(to, from, :second), 0)

  defp item_runtime_seconds(_item, _overview, _now), do: 0

  defp displayed_count(assigns) do
    assigns.shown_history_count + if(assigns.active_session, do: 1, else: 0)
  end

  defp hidden_count(%{node_filter: "all"}), do: 0

  defp hidden_count(%{total_history: total, shown_history_count: shown}),
    do: max(total - shown, 0)

  defp unsaved_active?(%Session{save: false, config: %Config{}}), do: true
  defp unsaved_active?(_active), do: false

  defp session_path(%{node_name: node_name}, id), do: ~p"/node/#{node_name}/tracing/#{id}"

  defp confirm_kind({kind, _payload}), do: kind
  defp confirm_kind(kind), do: kind

  defp removed_copy(0), do: "will be removed from history."
  defp removed_copy(1), do: "and its 1 trace will be removed from history."

  defp removed_copy(traces),
    do: "and its #{Formatters.format_integer(traces)} traces will be removed from history."

  defp confirm_title(:stop), do: "Stop session"
  defp confirm_title(:delete), do: "Delete session"
  defp confirm_title(:unload), do: "Unload session"
  defp confirm_title(:load), do: "Load session"
  defp confirm_title(kind) when kind in [:create, :copy], do: "Save the new session?"

  defp confirm_label(:stop), do: "Stop"
  defp confirm_label(:delete), do: "Delete"
  defp confirm_label(:unload), do: "Unload"
  defp confirm_label(:load), do: "Load anyway"
  defp confirm_label(kind) when kind in [:create, :copy], do: "Yes"

  defp confirm_class(kind) when kind in [:load, :create, :copy], do: "btn-primary"
  defp confirm_class(_kind), do: "btn-error dark:text-base-100"
  defp query_node("all"), do: nil
  defp query_node(node), do: node

  defp parse_node_filter(%{"node" => "all"}, _connected), do: "all"

  defp parse_node_filter(%{"node" => node}, _connected) when is_binary(node) and node != "",
    do: node

  defp parse_node_filter(_params, connected), do: connected

  defp parse_selected_id(%{"session" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} when id <= @max_row_id -> id
      _invalid -> nil
    end
  end

  defp parse_selected_id(_params), do: nil

  defp drop_or_put(url, key, nil), do: URL.drop_query_param(url, key)
  defp drop_or_put(url, key, value), do: URL.put_query_param(url, key, value)

  defp format_error(:busy), do: "A tracing session is running. Stop it first."
  defp format_error(:not_found), do: "No such tracing session."
  defp format_error(:no_session), do: "This session is no longer active."
  defp format_error(:exit), do: "The tracer did not respond. Try again."
  defp format_error(reason), do: "Tracing failed: #{inspect(reason)}"
end
