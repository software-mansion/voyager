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

  @node_name node_name()

  setup :setup_tracer

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

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

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

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

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

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#create-session[aria-disabled]")
    refute has_element?(view, "#history-tiles #history-#{oldest.id}")
    assert has_element?(view, "#show-older")

    view
    |> element("#show-older")
    |> render_click()

    assert has_element?(view, "#history-tiles #history-#{oldest.id}")
    refute has_element?(view, "#show-older")
  end

  test "creates a session with the Save toggle and warns before replacing an unsaved one", %{
    conn: conn
  } do
    create!()
    {:ok, _session} = configure()

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    view
    |> element("#save-new-session")
    |> render_click()

    view
    |> element("#create-session")
    |> render_click()

    assert has_element?(view, "#create-session-modal")

    view
    |> element("#create-session-modal-confirm")
    |> render_click()

    {path, _flash} = assert_redirect(view)
    active = Tracer.active()
    assert active.save
    assert path == ~p"/node/#{@node_name}/tracing/#{active.id}"
  end

  test "stops a running session after confirmation and unloads it", %{conn: conn} do
    active = create!(save: true)
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

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

  test "loads a saved session from this node and deletes one after confirmation", %{conn: conn} do
    first = insert_saved!(%{dropped: 5})
    second = insert_saved!()

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing?session=#{first.id}")

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

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

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

    {path, _flash} = assert_redirect(view)
    active = Tracer.active()
    assert active.node == Node.self()
    assert active.config.module == "Elixir.Date"
    assert path == ~p"/node/#{@node_name}/tracing/#{active.id}"
  end

  test "renders overview Runs, Activity, Outcome and Top functions cards", %{conn: conn} do
    first_cfg = %Config{
      module: "Elixir.Date",
      function: "_",
      arity: nil,
      return_trace: true,
      max_events: 100
    }

    second_cfg = %{first_cfg | scope: :local}

    saved =
      insert_saved!(%{
        config: second_cfg,
        runs: 0,
        traces: 8,
        stop_reason: :event_limit
      })

    pid_a = self()
    pid_b = spawn(fn -> :ok end)

    TraceEntryActions.insert_all(saved.id, [
      %{
        seq: 0,
        kind: :configured,
        at: 1_000_000,
        origin: :ui,
        node: Node.self(),
        config: first_cfg
      },
      %{seq: 1, kind: :started, at: 2_000_000, origin: :ui},
      %{
        seq: 2,
        kind: :trace,
        type: :call,
        pid: pid_a,
        process: :worker_a,
        mfa: {Date, :f1, 1},
        at: 3_000_000
      },
      %{
        seq: 3,
        kind: :trace,
        type: :return,
        pid: pid_a,
        process: :worker_a,
        mfa: {Date, :f1, 1},
        value: :ok,
        duration_us: 10,
        at: 4_000_000
      },
      %{
        seq: 4,
        kind: :stopped,
        at: 6_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 2,
        dropped: 0
      },
      %{
        seq: 5,
        kind: :configured,
        at: 7_000_000,
        origin: :ui,
        node: Node.self(),
        config: second_cfg
      },
      %{seq: 6, kind: :started, at: 8_000_000, origin: :mcp},
      %{
        seq: 7,
        kind: :trace,
        type: :call,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f2, 1},
        at: 9_000_000
      },
      %{
        seq: 8,
        kind: :trace,
        type: :call,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f3, 1},
        at: 9_100_000
      },
      %{
        seq: 9,
        kind: :trace,
        type: :call,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f4, 1},
        at: 9_200_000
      },
      %{
        seq: 10,
        kind: :trace,
        type: :call,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f5, 1},
        at: 9_300_000
      },
      %{
        seq: 11,
        kind: :trace,
        type: :call,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f6, 1},
        at: 9_400_000
      },
      %{
        seq: 12,
        kind: :trace,
        type: :exception,
        pid: pid_b,
        process: :worker_b,
        mfa: {Date, :f6, 1},
        value: :boom,
        duration_us: 20,
        at: 9_500_000
      },
      %{
        seq: 13,
        kind: :stopped,
        at: 12_000_000,
        origin: :mcp,
        reason: :event_limit,
        traces: 6,
        dropped: 0
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")
    render_async(view)

    assert has_element?(view, "#overview-runs", "2 runs")
    assert has_element?(view, "#overview-runs", "Scope")
    assert has_element?(view, "#overview-run-1", "Stopped on request")
    assert has_element?(view, "#overview-run-2", "Event limit reached")
    assert has_element?(view, "#overview-activity", "traces over all runs")
    assert has_element?(view, "#overview-outcome", "Exceptions")
    assert has_element?(view, "#outcome-processes", "2")
    assert has_element?(view, "#overview-functions", "others (1)")
  end
end
