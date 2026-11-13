defmodule VoyagerWeb.TracingSessionsLive do
  @moduledoc """
  Landing page for Tracing (`/node/:node/tracing`): lists the active tracing
  session pinned above paginated saved history, with a node filter and an
  overview of the selected session.
  """

  use VoyagerWeb, :live_view

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session
  alias Voyager.Services.Tracer.Writer
  alias VoyagerWeb.Components.TracingBrowserComponents
  alias VoyagerWeb.Utils.URL

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :tracing)
    |> assign(:save_new?, false)
    |> assign(:pending, nil)
    |> assign(:active_session, nil)
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
    |> stream(:history, [])
    |> load_initial()
    |> ok()
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
    assigns =
      assign(assigns,
        selected_item: selected_item(assigns),
        displayed_count: displayed_count(assigns),
        hidden_count: hidden_count(assigns)
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
            busy?={match?(%Session{status: :running}, @active_session)}
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
            :if={!@history_empty?}
            type="button"
            id="show-older"
            phx-click="show-older"
            disabled={!@has_more?}
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
        <div
          :if={@selected_item}
          id="session-card"
          data-session-id={@selected_item.id}
          class="card bg-base-100 border-base-200 text-base-content flex-none border px-5 py-4 shadow-sm"
        >
          <h2 id="overview-mfa" class="font-mono text-base-content truncate text-lg font-semibold">
            {elem(TracingBrowserComponents.item_mfa_parts(@selected_item.config), 0)}{elem(
              TracingBrowserComponents.item_mfa_parts(@selected_item.config),
              1
            )}
          </h2>
        </div>
      </section>
    </div>
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

  def handle_event("create-session", _params, socket), do: noreply(socket)

  defp load_initial(socket) do
    Writer.flush()
    active = Tracer.active()

    socket
    |> assign(:active_session, active)
    |> reload_history()
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
end
