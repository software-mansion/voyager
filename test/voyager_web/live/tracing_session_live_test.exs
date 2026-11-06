defmodule VoyagerWeb.TracingSessionLiveTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer

  @node_name node_name()

  setup :setup_tracer

  test "navigates back to the sessions on a malformed id", %{conn: conn} do
    sessions_path = ~p"/node/#{@node_name}/tracing"

    assert {:error, {:live_redirect, %{to: ^sessions_path, flash: %{"error" => _}}}} =
             live(conn, ~p"/node/#{@node_name}/tracing/12abc")
  end

  test "navigates back to the sessions on an unknown id", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/987654")

    assert %{"error" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
  end

  test "stops a running session", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    view = open(conn, id)

    assert has_element?(view, "#session-status[data-tone=running]")
    assert has_element?(view, "#session-meta", "run started")
    assert has_element?(view, "#session-edit[disabled]")

    assert view
           |> element("#session-edit-tip-portal")
           |> render() =~ "Stop the session"

    refute has_element?(view, "#session-resume")
    refute has_element?(view, "#session-unload")

    view
    |> element("#session-stop")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-resume:not([disabled])")
    assert has_element?(view, "#session-unload:not([disabled])")
    assert has_element?(view, "#session-edit[disabled]")
    refute has_element?(view, "#session-stop")
  end

  test "resumes a stopped session", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)
    :ok = Tracer.stop(:ui)
    _ = :sys.get_state(Tracer)

    view = open(conn, id)
    assert has_element?(view, "#session-status[data-tone=open]")

    view
    |> element("#session-resume")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-stop")
    refute has_element?(view, "#session-resume")
  end

  test "shows the empty state for an unconfigured session", %{conn: conn} do
    %{id: id} = create!()

    view = open(conn, id)

    assert has_element?(view, "#session-start[disabled]")
    assert has_element?(view, "#session-empty")
    assert has_element?(view, "#session-set-parameters[disabled]")
    assert has_element?(view, "#session-chip-storage", "Not saved")
    refute has_element?(view, "#session-edit")
  end

  test "starts a configured session", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()

    view = open(conn, id)

    assert has_element?(view, "#session-edit[disabled]")

    assert view
           |> element("#session-edit-tip-portal")
           |> render() =~ "not available yet"

    refute has_element?(view, "#session-empty")
    assert has_element?(view, "#log-footer", "No traces yet")
    assert has_element?(view, "#log-search[disabled]")

    view
    |> element("#session-start:not([disabled])")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-stop")
  end

  test "summarizes the config and shows what each reconfigure changed", %{conn: conn} do
    %{id: id} = create!()

    {:ok, _session} =
      configure(%{
        processes: :all,
        capture: :args,
        budget: 5_000,
        return_trace: true,
        max_rate: 1_000,
        max_events: 10_000,
        max_time_ms: 300_000
      })

    view = open(conn, id)

    assert has_element?(view, "#session-mfa", "Date.leap_year?/1")

    assert has_element?(view, "#session-chip-where", "All processes · global")
    assert has_element?(view, "#session-chip-capture", "Args ≤ 5,000 + returns")
    assert has_element?(view, "#session-chip-stop_after", "10,000 events · 1,000/s · 5 min")

    assert view
           |> element("#session-params-portal")
           |> render() =~ "Max rate"

    assert has_element?(view, "#entry-0-changes", "by UI · Date.leap_year?/1")

    {:ok, _session} = configure(%{scope: :local, max_events: nil, max_time_ms: 90_000})

    assert has_element?(view, "#session-chip-where", "1 pid · local")
    assert has_element?(view, "#session-chip-capture", "Arity")
    assert has_element?(view, "#session-chip-stop_after", "90 s")

    assert has_element?(
             view,
             "#entry-1-changes",
             "Processes All processes → " <> Voyager.Pid.format(self(), :distribution)
           )

    assert has_element?(view, "#entry-1-changes", "Scope Global → Local")
    assert has_element?(view, "#entry-1-changes .line-through", "Global")
    assert has_element?(view, "#entry-1-changes", "Max events 10,000 → None")
    assert has_element?(view, "#entry-1-config-portal")
  end

  test "names the term column for a wildcard function", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure(%{function: "_", arity: nil})

    view = open(conn, id)

    assert has_element?(view, "#session-log th", "Call / result")
  end

  test "loads a saved session into the tracer", %{conn: conn} do
    %{id: id} = saved_inactive!()

    view = open(conn, id)
    refute has_element?(view, "#session-start")
    assert has_element?(view, "#session-saved")
    assert has_element?(view, "#session-meta", "Never run")

    view
    |> element("#session-load")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-start")
    refute has_element?(view, "#session-load")
  end

  test "flashes why a saved session cannot be loaded", %{conn: conn} do
    %{id: id} = saved_inactive!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    view = open(conn, id)

    view
    |> element("#session-load")
    |> render_click()

    settle(view)

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#session-load:not([disabled])")
  end

  test "deletes a saved session only once confirmed", %{conn: conn} do
    %{id: id} = saved_inactive!()

    view = open(conn, id)

    view
    |> element("#session-delete")
    |> render_click()

    view
    |> element("#delete-session-cancel")
    |> render_click()

    refute has_element?(view, "#delete-session-modal")
    assert TraceSessionQueries.get(id)

    view
    |> element("#session-delete")
    |> render_click()

    view
    |> element("#delete-session-modal #delete-session-confirm")
    |> render_click()

    assert %{"info" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
    refute TraceSessionQueries.get(id)
  end

  test "unloads a saved session from the tracer", %{conn: conn} do
    %{id: id} = create!(save: true)
    {:ok, _session} = configure()
    view = open(conn, id)

    view
    |> element("#session-unload")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-load")
    refute has_element?(view, "#session-unload")
  end

  test "unloads an unsaved session only once confirmed", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    view = open(conn, id)

    view
    |> element("#session-unload")
    |> render_click()

    view
    |> element("#unload-session-cancel")
    |> render_click()

    refute has_element?(view, "#unload-session-modal")
    assert has_element?(view, "#session-start")

    view
    |> element("#session-unload")
    |> render_click()

    view
    |> element("#unload-session-modal #unload-session-confirm")
    |> render_click()

    assert %{"info" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
  end

  test "navigates away once an unsaved session is closed", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    :ok = Tracer.close()

    assert %{"info" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
  end

  test "keeps showing a saved session once it is closed", %{conn: conn} do
    %{id: id} = create!(save: true)
    view = open(conn, id)
    assert has_element?(view, "#session-start")

    :ok = Tracer.close()
    render_async(view)

    assert has_element?(view, "#session-load")
    refute has_element?(view, "#session-start")
  end

  test "keeps showing a saved session once another one replaces it", %{conn: conn} do
    %{id: id} = create!(save: true)
    view = open(conn, id)

    create!()
    render_async(view)

    assert has_element?(view, "#session-load")
  end

  test "follows a saved session activated while it is open", %{conn: conn} do
    %{id: id} = saved_inactive!()
    view = open(conn, id)

    {:ok, _session} = Tracer.load(id)

    assert has_element?(view, "#session-start")
    refute has_element?(view, "#session-load")
  end

  test "flashes a readable reason when no function matches", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure(%{arity: 2})

    view = open(conn, id)

    view
    |> element("#session-start")
    |> render_click()

    settle(view)

    assert has_element?(view, "#flash-error", "No loaded function matches")
  end

  test "shows a broadcast for its session while the load waits on the Tracer", %{conn: conn} do
    session = create!()
    :ok = :sys.suspend(Tracer)
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{session.id}")

    send(view.pid, {:session_entries, session, []})

    assert has_element?(view, "#session-start")
    :ok = :sys.resume(Tracer)
    render_async(view)
    assert has_element?(view, "#session-start")
  end

  test "navigates away once an unsaved session is replaced during its load", %{conn: conn} do
    session = create!()
    :ok = :sys.suspend(Tracer)
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{session.id}")

    send(view.pid, {:session_activated, %{session | id: session.id - 1}})

    assert %{"info" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
    :ok = :sys.resume(Tracer)
  end

  test "hides the run actions while a closed saved session reloads", %{conn: conn} do
    %{id: id} = create!(save: true)
    view = open(conn, id)
    :ok = :sys.suspend(Tracer)

    send(view.pid, {:session_closed, id})

    refute has_element?(view, "#session-start")
    :ok = :sys.resume(Tracer)
    render_async(view)
    assert has_element?(view, "#session-start")
  end

  test "shows the stats of a running session", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    assert has_element?(view, "#session-stats")
    assert has_element?(view, "#stat-events", "/ 1,000")
    assert has_element?(view, "#stat-storage", "Not saved")
  end

  test "updates the rate on each tick", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)
    assert has_element?(view, "#stat-rate", "0")

    call_traced!(3, 3)
    _ = :sys.get_state(Tracer)
    send(view.pid, :tick)

    assert has_element?(view, "#stat-rate", "3")
  end

  test "replaces the rate with the stop reason once stopped", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    :ok = Tracer.stop(:ui)
    settle(view)

    assert has_element?(view, "#stat-stop_reason", "Stopped on request")
    refute has_element?(view, "#stat-rate")
  end

  test "shows no stats before the first run", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()

    view = open(conn, id)

    assert has_element?(view, "#session-start")
    refute has_element?(view, "#session-stats")
  end
end
