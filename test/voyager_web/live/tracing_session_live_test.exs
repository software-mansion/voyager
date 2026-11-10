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

  test "disables running a session traced on another node", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()

    :sys.replace_state(Tracer, fn state ->
      %{state | session: %{state.session | node: :other@localhost, status: :stopped}}
    end)

    view = open(conn, id)

    assert has_element?(view, "#session-resume[disabled]")
    assert has_element?(view, "#session-unload:not([disabled])")

    assert view
           |> element("#session-run-tip-portal")
           |> render() =~ "other@localhost"
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
    |> element("#delete-session-modal-cancel")
    |> render_click()

    refute has_element?(view, "#delete-session-modal")
    assert TraceSessionQueries.get(id)

    view
    |> element("#session-delete")
    |> render_click()

    view
    |> element("#delete-session-modal-confirm")
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
    |> element("#unload-session-modal")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#unload-session-modal")
    assert has_element?(view, "#session-start")

    view
    |> element("#session-unload")
    |> render_click()

    view
    |> element("#unload-session-modal-confirm")
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
end
