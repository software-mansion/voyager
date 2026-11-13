defmodule VoyagerWeb.TracingSessionsLive do
  @moduledoc """
  Landing page for Tracing (`/node/:node/tracing`): lists the active tracing
  session pinned above paginated saved history, with a node filter and an
  overview of the selected session.
  """

  use VoyagerWeb, :live_view

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

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :tracing)
      |> assign(:save_new?, false)
      |> assign(:pending, nil)
      |> assign(:confirm, nil)
      |> assign(:active_session, nil)
      |> assign(:queued_active, nil)
      |> assign(:flush_scheduled?, false)
      |> assign(:tick_scheduled?, false)
      |> assign(:node_filter, socket.assigns.session.node_name)
      |> assign(:node_counts, %{})
      |> assign(:total_history, 0)
      |> assign(:shown_history_count, 0)
      |> assign(:history_empty?, true)
      |> assign(:has_more?, false)
      |> assign(:oldest_id, nil)
      |> assign(:history_by_id, %{})
      |> assign(:selected_id, nil)
      |> assign(:selected_param, nil)
      |> assign(:used_bytes, 0)
      |> assign(:storage_limit_mb, Tracer.storage_limit_mb())
      |> assign(:now, DateTime.utc_now())
      |> TracingStatusHook.defer_puts()
      |> stream(:history, [])

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
        load_initial(socket)
      else
        socket
      end

    ok(socket)
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

    socket = if filter_changed?, do: reload_history(socket), else: socket

    socket
    |> resolve_selection()
    |> noreply()
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
        runtime_seconds: item_runtime_seconds(selected, assigns.now)
      )

    ~H"""
    <div
      id="tracing-sessions-page"
      class="mx-auto flex h-full max-w-screen-2xl gap-4 p-6 sm:p-8"
    >
      <section
        id="sessions-list-card"
        class="card bg-base-100 border-base-200 min-w-80 flex w-1/3 max-w-md flex-none flex-col border shadow-sm"
      >
        <div class="border-base-200 flex flex-col gap-3 border-b px-5 py-4">
          <TracingBrowserComponents.list_header
            count={@displayed_count}
            save?={@save_new?}
            busy?={@busy?}
            pending?={@pending != nil}
            on_toggle_save="toggle-save"
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

      <section id="overview" class="flex min-w-0 flex-1 flex-col gap-4 overflow-y-auto">
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
  attr :active_session, :any, default: nil
  attr :selected_item, :any, default: nil

  defp browser_confirm_modal(assigns) do
    kind = confirm_kind(assigns.confirm)
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <TracingComponents.confirm_modal
      id={"#{@kind}-session-modal"}
      title={confirm_title(@kind)}
      confirm_label={confirm_label(@kind)}
      confirm_class={confirm_class(@kind)}
      on_confirm="confirm-action"
      on_cancel="cancel-confirm"
    >
      <p :if={@kind == :stop and @active_session != nil} class="text-base-content/70 mt-1 text-sm">
        Tracing <span class="font-mono">{TracingComponents.traced_mfa(@active_session.config)}</span>
        on <span class="font-mono">{@active_session.node}</span>
        stops. Its {Formatters.format_integer(@active_session.traces)} traces {if @active_session.save,
          do: "stay saved",
          else: "are kept"}, and you can resume it from the session page.
      </p>
      <p :if={@kind == :delete and @selected_item != nil} class="text-base-content/70 mt-1 text-sm">
        <span :if={@selected_item.config} class="font-mono">
          {TracingComponents.traced_mfa(@selected_item.config)}
        </span>
        <span :if={!@selected_item.config}>This session</span>
        and its {Formatters.format_integer(@selected_item.traces)} traces will be removed from history.
      </p>
      <p :if={@kind == :unload} class="text-base-content/70 mt-1 text-sm">
        This session is not saved, so its traces are lost.
      </p>
      <p :if={@kind == :load} class="text-base-content/70 mt-1 text-sm">
        Loading discards the unsaved active session.
      </p>
      <p :if={@kind in [:create, :copy]} class="text-base-content/70 mt-1 text-sm">
        The active session is not saved. Creating a new one discards it.
      </p>
    </TracingComponents.confirm_modal>
    """
  end

  @impl true
  def handle_event("toggle-save", _params, socket) do
    socket
    |> update(:save_new?, &(not &1))
    |> noreply()
  end

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
      {id, ""} ->
        socket
        |> update_selected_tile(id)
        |> push_patch(to: URL.put_query_param(socket.assigns.current_url, "session", raw_id))
        |> noreply()

      _invalid ->
        noreply(socket)
    end
  end

  def handle_event("show-older", _params, %{assigns: %{has_more?: false}} = socket),
    do: noreply(socket)

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
    |> confirm_or_run(:create, &start_create/1)
    |> noreply()
  end

  def handle_event("stop-session", _params, socket) do
    socket
    |> assign(:confirm, :stop)
    |> noreply()
  end

  def handle_event("unload-session", _params, socket) do
    socket
    |> confirm_or_run(:unload, &run_action(&1, :unload, fn -> Tracer.close() end))
    |> noreply()
  end

  def handle_event("load-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{id: id} when id > 0 ->
        socket
        |> confirm_or_run({:load, id}, &run_action(&1, :load, fn -> Tracer.load(id) end))
        |> noreply()

      _other ->
        noreply(socket)
    end
  end

  def handle_event("copy-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{config: config} = item when not is_struct(item, Session) ->
        socket
        |> confirm_or_run({:copy, config}, &start_copy(&1, config))
        |> noreply()

      _other ->
        noreply(socket)
    end
  end

  def handle_event("delete-session", _params, socket) do
    case selected_item(socket.assigns) do
      %{id: id} = item when not is_struct(item, Session) and id > 0 ->
        socket
        |> assign(:confirm, {:delete, id})
        |> noreply()

      _other ->
        noreply(socket)
    end
  end

  def handle_event("cancel-confirm", _params, socket) do
    socket
    |> assign(:confirm, nil)
    |> noreply()
  end

  def handle_event("confirm-action", _params, socket) do
    confirm = socket.assigns.confirm
    socket = assign(socket, :confirm, nil)

    socket
    |> execute_confirmed(confirm)
    |> noreply()
  end

  @impl true
  def handle_async(name, {:ok, {:ok, %Session{id: id}}}, socket) when name in [:create, :copy] do
    socket
    |> assign(:pending, nil)
    |> push_navigate(to: session_path(socket.assigns.session, id))
    |> noreply()
  end

  def handle_async(:delete, {:ok, {:ok, deleted}}, socket) do
    socket
    |> assign(:pending, nil)
    |> remove_deleted_row(deleted.id)
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
        noreply(socket)
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
    |> schedule_tick()
    |> noreply()
  end

  def handle_info(_message, socket), do: noreply(socket)

  defp execute_confirmed(socket, :create), do: start_create(socket)
  defp execute_confirmed(socket, :stop), do: run_action(socket, :stop, fn -> Tracer.stop(:ui) end)
  defp execute_confirmed(socket, :unload), do: run_action(socket, :unload, &Tracer.close/0)

  defp execute_confirmed(socket, {:load, id}),
    do: run_action(socket, :load, fn -> Tracer.load(id) end)

  defp execute_confirmed(socket, {:copy, config}), do: start_copy(socket, config)

  defp execute_confirmed(socket, {:delete, id}),
    do: run_action(socket, :delete, fn -> Tracer.delete(id) end)

  defp execute_confirmed(socket, _nil), do: socket

  defp confirm_or_run(socket, confirm, fun) do
    if unsaved_active?(socket.assigns.active_session),
      do: assign(socket, :confirm, confirm),
      else: fun.(socket)
  end

  defp start_create(socket) do
    save? = socket.assigns.save_new?
    run_action(socket, :create, fn -> Tracer.create(:ui, save: save?) end)
  end

  defp start_copy(socket, config) do
    save? = socket.assigns.save_new?
    node = socket.assigns.session.node

    run_action(socket, :copy, fn ->
      with {:ok, session} <- Tracer.create(:ui, save: save?) do
        copy_config_to_node(node, config, session)
      end
    end)
  end

  defp copy_config_to_node(_node, nil, session), do: {:ok, session}
  defp copy_config_to_node(_node, %Config{processes: :pids}, session), do: {:ok, session}

  defp copy_config_to_node(node, %Config{} = config, session) do
    case Tracer.configure(node, Map.from_struct(config), :ui) do
      {:ok, configured} -> {:ok, configured}
      {:error, _reason} -> {:ok, session}
    end
  end

  defp run_action(socket, name, fun) do
    socket
    |> assign(:pending, name)
    |> start_async(name, fun)
  end

  defp load_initial(socket) do
    Writer.flush()
    active = Tracer.active()

    socket
    |> assign(:active_session, active)
    |> reload_history()
    |> schedule_tick()
  end

  defp apply_active_change(socket, next_active) do
    prev_active = socket.assigns.active_session

    socket
    |> assign(:active_session, next_active)
    |> assign(:queued_active, nil)
    |> drop_stale_confirm(next_active)
    |> reload_history()
    |> adjust_selection_after_active_change(prev_active, next_active)
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
      do: update_selected_tile(socket, prev_id),
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
    socket
    |> assign(:active_session, session)
    |> assign(:queued_active, nil)
    |> assign(:used_bytes, TraceSessionQueries.bytes_except(0))
    |> drop_stale_confirm(session)
    |> schedule_tick()
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

  defp drop_stale_confirm(socket, _active), do: socket

  defp remove_deleted_row(socket, id) do
    row = Map.get(socket.assigns.history_by_id, id)
    socket = if row, do: stream_delete(socket, :history, row), else: socket

    socket =
      socket
      |> reload_history()

    if socket.assigns.selected_id == id do
      socket
      |> assign(:selected_param, nil)
      |> assign(:selected_id, nil)
      |> resolve_selection()
    else
      socket
    end
  end

  defp reload_history(socket) do
    %{node_filter: node_filter, active_session: active} = socket.assigns
    exclude_id = active && active.id
    node_counts = TraceSessionQueries.counts_by_node(exclude_id)
    total_history = TraceSessionQueries.total_count(exclude_id)
    used_bytes = TraceSessionQueries.bytes_except(0)

    page =
      TraceSessionQueries.page(
        limit: @page_size,
        node: query_node(node_filter),
        exclude_id: exclude_id
      )

    shown_history =
      if node_filter == "all",
        do: total_history,
        else: Map.get(node_counts, node_filter, 0)

    socket
    |> assign(:node_counts, node_counts)
    |> assign(:total_history, total_history)
    |> assign(:shown_history_count, shown_history)
    |> assign(:history_empty?, page.rows == [])
    |> assign(:has_more?, page.has_more?)
    |> assign(:oldest_id, List.last(page.rows, %{id: nil}).id)
    |> assign(:history_by_id, Map.new(page.rows, &{&1.id, &1}))
    |> assign(:used_bytes, used_bytes)
    |> assign(:now, DateTime.utc_now())
    |> stream(:history, page.rows, reset: true)
  end

  defp resolve_selection(socket) do
    %{
      selected_param: param_id,
      active_session: active,
      history_by_id: by_id,
      node_filter: node_filter
    } = socket.assigns

    case target_selection(param_id, active, by_id, node_filter) do
      {id, nil} ->
        update_selected_tile(socket, id)

      {id, extra_row} ->
        socket
        |> update(:history_by_id, &Map.put(&1, extra_row.id, extra_row))
        |> update_selected_tile(id)
    end
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

  defp update_selected_tile(socket, next_id) do
    prev_id = socket.assigns.selected_id
    by_id = socket.assigns.history_by_id

    socket = assign(socket, :selected_id, next_id)

    socket =
      if prev_id != next_id and Map.has_key?(by_id, prev_id),
        do: stream_insert(socket, :history, by_id[prev_id]),
        else: socket

    if prev_id != next_id and Map.has_key?(by_id, next_id),
      do: stream_insert(socket, :history, by_id[next_id]),
      else: socket
  end

  defp default_selected_id(%Session{id: id}, _by_id), do: id

  defp default_selected_id(nil, by_id) do
    by_id
    |> Map.keys()
    |> Enum.max(fn -> nil end)
  end

  defp selected_item(%{selected_id: nil}), do: nil
  defp selected_item(%{selected_id: id, active_session: %Session{id: id} = active}), do: active
  defp selected_item(%{selected_id: id, history_by_id: by_id}), do: Map.get(by_id, id)

  defp item_runtime_seconds(nil, _now), do: 0
  defp item_runtime_seconds(%{started_at: nil}, _now), do: 0

  defp item_runtime_seconds(%Session{status: :running, run_started_at: %DateTime{} = at}, now),
    do: max(DateTime.diff(now, at, :second), 0)

  defp item_runtime_seconds(
         %{started_at: %DateTime{} = from, stopped_at: %DateTime{} = to},
         _now
       ),
       do: max(DateTime.diff(to, from, :second), 0)

  defp item_runtime_seconds(_item, _now), do: 0

  defp displayed_count(assigns) do
    active_count =
      case assigns.active_session do
        nil ->
          0

        active ->
          if matches_filter?(active, assigns.node_filter, assigns.session.node_name),
            do: 1,
            else: 0
      end

    assigns.shown_history_count + active_count
  end

  defp hidden_count(%{node_filter: "all"}), do: 0

  defp hidden_count(%{total_history: total, shown_history_count: shown}),
    do: max(total - shown, 0)

  defp matches_filter?(_active, "all", _connected_node), do: true

  defp matches_filter?(%Session{node: nil}, filter, connected_node),
    do: filter == connected_node

  defp matches_filter?(%Session{node: node}, filter, _connected_node),
    do: Atom.to_string(node) == filter

  defp unsaved_active?(%Session{save: false, config: %Config{}}), do: true
  defp unsaved_active?(_active), do: false

  defp session_path(%{node_name: node_name}, id), do: ~p"/node/#{node_name}/tracing/#{id}"

  defp confirm_kind({kind, _payload}), do: kind
  defp confirm_kind(kind), do: kind

  defp confirm_title(:stop), do: "Stop session"
  defp confirm_title(:delete), do: "Delete session"
  defp confirm_title(:unload), do: "Unload session"
  defp confirm_title(:load), do: "Load session"
  defp confirm_title(kind) when kind in [:create, :copy], do: "Replace session"

  defp confirm_label(:stop), do: "Stop"
  defp confirm_label(:delete), do: "Delete"
  defp confirm_label(:unload), do: "Unload"
  defp confirm_label(:load), do: "Load anyway"
  defp confirm_label(kind) when kind in [:create, :copy], do: "Create anyway"

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
      {id, ""} -> id
      _invalid -> nil
    end
  end

  defp parse_selected_id(_params), do: nil

  defp drop_or_put(url, key, nil), do: URL.drop_query_param(url, key)
  defp drop_or_put(url, key, value), do: URL.put_query_param(url, key, value)

  defp format_error(:busy), do: "A tracing session is running. Stop it first."
  defp format_error(:not_found), do: "No such tracing session."
  defp format_error(:exit), do: "The tracer did not respond. Try again."
  defp format_error(reason), do: "Tracing failed: #{inspect(reason)}"
end
