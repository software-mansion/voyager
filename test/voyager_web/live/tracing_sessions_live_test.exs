defmodule VoyagerWeb.TracingSessionsLiveTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Writer

  @node_name node_name()

  setup :setup_tracer

  defp open_sessions(conn, path \\ ~p"/node/#{@node_name}/tracing") do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp insert_saved!(overrides \\ %{}) do
    config =
      Map.get(overrides, :config, %Config{
        module: "Elixir.Date",
        function: "leap_year?",
        arity: 1,
        max_events: 100
      })

    row =
      Repo.insert!(%TraceSession{
        origin: Map.get(overrides, :origin, :ui),
        status: Map.get(overrides, :status, :stopped),
        node: Map.get(overrides, :node, @node_name),
        config: config && Map.from_struct(config),
        stop_reason: Map.get(overrides, :stop_reason, :stopped),
        traces: Map.get(overrides, :traces, 42),
        dropped: Map.get(overrides, :dropped, 0),
        bytes: Map.get(overrides, :bytes, 2_000),
        started_at: ~U[2026-11-12 10:00:00.000000Z],
        stopped_at: ~U[2026-11-12 10:01:00.000000Z]
      })

    runs = Map.get(overrides, :runs, 1)

    if runs > 0 do
      events =
        for idx <- 1..runs do
          %{seq: idx - 1, kind: :started, at: idx * 1_000_000, origin: :ui}
        end

      TraceEntryActions.insert_all(row.id, events)
    end

    row
  end

  test "renders empty state with other-node count and switches to all nodes", %{conn: conn} do
    other = insert_saved!(%{node: "worker@127.0.0.1", stop_reason: :interrupted})

    view = open_sessions(conn)

    assert has_element?(view, "#session-count", "0")
    assert has_element?(view, "#node-filter-chip", @node_name)
    assert has_element?(view, "#tiles-empty", "1 saved on other nodes")
    assert has_element?(view, "#overview-empty")
    assert has_element?(view, "#storage-footer", "2 KB")

    view
    |> element("#tiles-show-all-nodes")
    |> render_click()

    assert_patch(view, ~p"/node/#{@node_name}/tracing?node=all")
    assert has_element?(view, "#node-picker-trigger", "All nodes")
    assert has_element?(view, "#session-count", "1")
    assert has_element?(view, "#history-tiles button[data-tone=error]", "worker@127.0.0.1")
    assert has_element?(view, "#session-card[data-session-id='#{other.id}']")
  end

  test "pins the active session once and excludes its saved row from history", %{conn: conn} do
    older = insert_saved!(%{runs: 2, traces: 120})
    active = create!(save: true)
    {:ok, _session} = configure()

    view = open_sessions(conn)

    assert has_element?(view, "#active-session-tile[data-selected]", "Active")
    refute has_element?(view, "#history-tiles #history-#{active.id}")
    assert has_element?(view, "#history-tiles #history-#{older.id}", "120 traces · 2 runs")
    assert has_element?(view, "#session-count", "2")

    view
    |> element("#history-tiles #history-#{older.id}")
    |> render_click()

    assert_patch(view, ~p"/node/#{@node_name}/tracing?session=#{older.id}")
    assert has_element?(view, "#session-card[data-session-id='#{older.id}']")
  end

  test "paginates history with Show older and disables create while running", %{conn: conn} do
    rows = for _ <- 1..22, do: insert_saved!()
    oldest = List.first(rows)

    create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    view = open_sessions(conn)

    assert has_element?(view, "#create-session[aria-disabled]")
    refute has_element?(view, "#history-tiles #history-#{oldest.id}")
    assert has_element?(view, "#show-older")

    view
    |> element("#show-older")
    |> render_click()

    assert has_element?(view, "#history-tiles #history-#{oldest.id}")
    refute has_element?(view, "#show-older")
  end

  test "deep-links a session beyond page 1 without disturbing history order", %{conn: conn} do
    rows = for _ <- 1..22, do: insert_saved!()
    oldest = List.first(rows)
    second_oldest = Enum.at(rows, 1)

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{oldest.id}")

    assert has_element?(view, "#session-card[data-session-id='#{oldest.id}']")
    refute has_element?(view, "#history-tiles #history-#{oldest.id}")

    view
    |> element("#show-older")
    |> render_click()

    assert has_element?(view, "#history-tiles #history-#{oldest.id}[data-selected]")

    tile_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#history-tiles > button")
      |> LazyHTML.attribute("id")

    assert Enum.take(tile_ids, -2) == ["history-#{second_oldest.id}", "history-#{oldest.id}"]
  end

  test "falls back to default selection when ?session is hidden by the filter or unknown", %{
    conn: conn
  } do
    local = insert_saved!()
    foreign = insert_saved!(%{node: "worker@127.0.0.1"})

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{foreign.id}")
    assert has_element?(view, "#session-card[data-session-id='#{local.id}']")

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{foreign.id + 999}")
    assert has_element?(view, "#session-card[data-session-id='#{local.id}']")
  end

  test "counts the pinned active tile when filtering by another node", %{conn: conn} do
    create!()
    {:ok, _session} = configure()

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?node=worker@127.0.0.1")

    assert has_element?(view, "#active-session-tile")
    assert has_element?(view, "#session-count", "1")
  end

  test "asks whether to save a new session and warns before replacing an unsaved one", %{
    conn: conn
  } do
    create!()
    {:ok, _session} = configure()

    view = open_sessions(conn)

    view
    |> element("#create-session")
    |> render_click()

    assert has_element?(view, "#create-session-modal #replace-unsaved-warning")

    view
    |> element("#create-session-modal-confirm")
    |> render_click()

    {path, _flash} = assert_redirect(view)
    active = Tracer.active()
    assert active.save
    assert path == ~p"/node/#{@node_name}/tracing/#{active.id}"
  end

  test "answering No creates an unsaved session and dismissing creates nothing", %{conn: conn} do
    view = open_sessions(conn)

    view
    |> element("#create-session")
    |> render_click()

    refute has_element?(view, "#replace-unsaved-warning")

    view
    |> element("#create-session-modal-backdrop")
    |> render_click()

    refute has_element?(view, "#create-session-modal")
    assert Tracer.active() == nil

    view
    |> element("#create-session")
    |> render_click()

    view
    |> element("#create-session-modal-cancel")
    |> render_click()

    assert_redirect(view)
    refute Tracer.active().save
  end

  test "stops a running session after confirmation and unloads it", %{conn: conn} do
    active = create!(save: true)
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    view = open_sessions(conn)

    assert has_element?(view, "#overview-status[data-tone=running]")
    refute has_element?(view, "#delete-session")

    view
    |> element("#stop-session")
    |> render_click()

    assert has_element?(view, "#stop-session-modal")

    view
    |> element("#stop-session-modal-confirm")
    |> render_click()

    settle(view)

    assert has_element?(view, "#overview-status[data-tone=open]")
    assert has_element?(view, "#unload-session")

    view
    |> element("#unload-session")
    |> render_click()

    settle(view)

    refute has_element?(view, "#active-session-tile")
    assert has_element?(view, "#history-tiles #history-#{active.id}")
    assert has_element?(view, "#load-session")
  end

  test "a session with no traces is removed without a zero count", %{conn: conn} do
    session = insert_saved!(%{traces: 0})
    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{session.id}")

    view
    |> element("#delete-session")
    |> render_click()

    assert has_element?(
             view,
             "#delete-session-modal span.font-mono.text-base-content",
             "Date.leap_year?/1"
           )

    assert has_element?(view, "#delete-session-modal", "session will be removed from history.")
    refute has_element?(view, "#delete-session-modal", "0 traces")
  end

  test "loads a saved session from this node and deletes one after confirmation", %{conn: conn} do
    first = insert_saved!(%{dropped: 5})
    second = insert_saved!()

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{first.id}")

    assert has_element?(view, "#total-dropped", "5")

    view
    |> element("#delete-session")
    |> render_click()

    assert has_element?(view, "#delete-session-modal")

    view
    |> element("#delete-session-modal-confirm")
    |> render_click()

    settle(view)

    refute TraceSessionQueries.get(first.id)
    refute has_element?(view, "#history-tiles #history-#{first.id}")
    assert has_element?(view, "#session-card[data-session-id='#{second.id}']")

    view
    |> element("#load-session")
    |> render_click()

    settle(view)

    assert has_element?(view, "#active-session-tile")
    assert Tracer.active().id == second.id
  end

  test "shows other-node note for active session and Trace on this node for foreign saved rows",
       %{
         conn: conn
       } do
    foreign =
      insert_saved!(%{
        node: "worker@127.0.0.1",
        config: %Config{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          processes: :all,
          max_events: 50
        }
      })

    create!(save: true)
    {:ok, _session} = configure()

    :sys.replace_state(Tracer, fn state ->
      %{
        state
        | session: %{
            state.session
            | node: :"worker@127.0.0.1",
              status: :stopped,
              stop_reason: :disconnected
          }
      }
    end)

    view = open_sessions(conn)

    assert has_element?(view, "#other-node-note", "worker@127.0.0.1")

    view
    |> element("#node-filter-clear")
    |> render_click()

    view
    |> element("#history-tiles #history-#{foreign.id}")
    |> render_click()

    refute has_element?(view, "#load-session")
    assert has_element?(view, "#trace-here")

    view
    |> element("#trace-here")
    |> render_click()

    view
    |> element("#copy-session-modal-cancel")
    |> render_click()

    {path, _flash} = assert_redirect(view)
    active = Tracer.active()
    refute active.save
    assert active.node == Node.self()
    assert active.config.module == "Elixir.Date"
    assert path == ~p"/node/#{@node_name}/tracing/#{active.id}"
  end

  test "confirms before unloading or replacing an unsaved configured session", %{conn: conn} do
    saved = insert_saved!()
    unsaved = create!(save: false)
    {:ok, _session} = configure()

    view = open_sessions(conn)

    view
    |> element("#unload-session")
    |> render_click()

    assert has_element?(view, "#unload-session-modal")
    assert Tracer.active().id == unsaved.id

    view
    |> element("#unload-session-modal-confirm")
    |> render_click()

    settle(view)

    assert Tracer.active() == nil
    refute has_element?(view, "#active-session-tile")

    unsaved = create!(save: false)
    {:ok, _session} = configure()

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{saved.id}")

    view
    |> element("#load-session")
    |> render_click()

    assert has_element?(view, "#load-session-modal")
    assert Tracer.active().id == unsaved.id

    view
    |> element("#load-session-modal-confirm")
    |> render_click()

    settle(view)

    assert Tracer.active().id == saved.id
    assert has_element?(view, "#active-session-tile")
  end

  test "flashes when Trace on this node cannot copy the saved session's parameters", %{conn: conn} do
    foreign =
      insert_saved!(%{
        node: "worker@127.0.0.1",
        config: %Config{
          module: "erlang",
          function: "send",
          arity: 2,
          processes: :all,
          max_events: 50
        }
      })

    view =
      open_sessions(conn, ~p"/node/#{@node_name}/tracing?node=all&session=#{foreign.id}")

    view
    |> element("#trace-here")
    |> render_click()

    view
    |> element("#copy-session-modal-cancel")
    |> render_click()

    {path, flash} = assert_redirect(view)
    active = Tracer.active()
    assert active.config == nil
    assert flash["error"] =~ "Parameters could not be copied"
    assert path == ~p"/node/#{@node_name}/tracing/#{active.id}"
  end

  test "flashes and re-enables actions when an async action fails", %{conn: conn} do
    saved = insert_saved!()

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{saved.id}")

    {:ok, _deleted} = Tracer.delete(saved.id)

    view
    |> element("#load-session")
    |> render_click()

    settle(view)

    assert has_element?(view, "#flash-error", "No such tracing session.")
    assert has_element?(view, "#load-session")
    refute has_element?(view, "#load-session[disabled]")
  end

  test "updates the running session totals on live PubSub broadcasts and ticks", %{conn: conn} do
    start!()

    view = open_sessions(conn)

    assert has_element?(view, "#overview-status[data-tone=running]")
    assert has_element?(view, "#total-traces", "0")

    call_traced!(3, 3)
    put_queued(view)
    send(view.pid, :tick)

    assert has_element?(view, "#total-traces", "3")
    assert has_element?(view, "#active-session-tile", "3 traces")
  end

  test "describes an unloaded saved idle session as not started", %{conn: conn} do
    idle = insert_saved!(%{status: :idle, stop_reason: nil, runs: 0, traces: 0})

    view = open_sessions(conn, ~p"/node/#{@node_name}/tracing?session=#{idle.id}")

    assert has_element?(view, "#overview-status", "Ready")
    assert has_element?(view, "#overview-meta", "Not started · created")
    refute has_element?(view, "#overview-meta", "Stopped")
  end

  test "mounts immediately while Tracer is blocked, ignores premature events, and loads on resume",
       %{conn: conn} do
    saved = insert_saved!()
    active = create!()
    {:ok, _session} = configure()

    :ok = :sys.suspend(Tracer)
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#sessions-loading")
    refute has_element?(view, "#sessions-list-card")

    render_click(view, "create-session", %{})
    refute has_element?(view, "#create-session-modal")

    :ok = :sys.resume(Tracer)
    render_async(view)

    refute has_element?(view, "#sessions-loading")
    assert has_element?(view, "#active-session-tile[data-selected]")
    assert has_element?(view, "#history-tiles #history-#{saved.id}")
    assert has_element?(view, "#session-card[data-session-id='#{active.id}']")
  end

  test "mounts immediately while Writer is blocked and loads once it resumes", %{conn: conn} do
    saved = insert_saved!()

    :ok = :sys.suspend(Writer)
    on_exit(fn -> :sys.resume(Writer) end)

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#sessions-loading")

    :ok = :sys.resume(Writer)
    render_async(view)

    assert has_element?(view, "#history-tiles #history-#{saved.id}")
  end

  test "applies a broadcast arriving during initial load and honors ?session", %{conn: conn} do
    saved = insert_saved!()
    active = create!()
    {:ok, _session} = configure()

    :ok = :sys.suspend(Tracer)
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing?session=#{saved.id}")

    send(view.pid, {:session_entries, active, []})

    assert has_element?(view, "#active-session-tile")
    assert has_element?(view, "#session-card[data-session-id='#{saved.id}']")

    :ok = :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#active-session-tile")
    assert has_element?(view, "#session-card[data-session-id='#{saved.id}']")
  end

  @tag capture_log: true
  test "renders saved history and flashes an error if initial load exits", %{conn: conn} do
    saved = insert_saved!()

    :ok = Supervisor.terminate_child(Voyager.Services.Tracer.Supervisor, Tracer)
    on_exit(fn -> Supervisor.restart_child(Voyager.Services.Tracer.Supervisor, Tracer) end)

    view = open_sessions(conn)

    assert has_element?(view, "#flash-error", "The tracer did not respond. Try again.")
    assert has_element?(view, "#history-tiles #history-#{saved.id}")
    assert has_element?(view, "#session-card[data-session-id='#{saved.id}']")
  end
end
