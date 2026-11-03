defmodule VoyagerWeb.TracingSessionLiveTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture
  alias VoyagerWeb.Formatters

  @node_name "nonode@nohost"

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    previous_state = :sys.get_state(Tracer)
    :sys.replace_state(Tracer, fn _ -> %Tracer{} end)
    on_exit(fn -> :sys.replace_state(Tracer, fn _ -> previous_state end) end)

    on_exit(fn ->
      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)
      Writer.flush()
    end)

    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

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
    assert has_element?(view, "#session-edit[disabled][title]")
    refute has_element?(view, "#session-resume")

    view |> element("#session-stop") |> render_click()
    settle(view)

    assert has_element?(view, "#session-resume:not([disabled])")
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

    view |> element("#session-resume") |> render_click()
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
    refute has_element?(view, "#session-edit[title]")
    refute has_element?(view, "#session-empty")

    view |> element("#session-start:not([disabled])") |> render_click()
    settle(view)

    assert has_element?(view, "#session-stop")
  end

  test "summarizes the config in chips", %{conn: conn} do
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
    assert has_element?(view, "#session-chip-stop_after", "10,000 · 1,000/s · 5 min")

    {:ok, _session} = configure(%{scope: :local, max_events: nil, max_time_ms: 90_000})

    assert has_element?(view, "#session-chip-where", "1 pids · local")
    assert has_element?(view, "#session-chip-capture", "Arity")
    assert has_element?(view, "#session-chip-stop_after", "90 s")
  end

  test "loads a saved session into the tracer", %{conn: conn} do
    %{id: id} = saved_inactive!()

    view = open(conn, id)
    refute has_element?(view, "#session-start")

    view |> element("#session-load") |> render_click()
    settle(view)

    assert has_element?(view, "#session-start")
    refute has_element?(view, "#session-load")
  end

  test "flashes why a saved session cannot be loaded", %{conn: conn} do
    %{id: id} = saved_inactive!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    view = open(conn, id)
    view |> element("#session-load") |> render_click()
    settle(view)

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#session-load:not([disabled])")
  end

  test "deletes a saved session only once confirmed", %{conn: conn} do
    %{id: id} = saved_inactive!()

    view = open(conn, id)

    view |> element("#session-delete") |> render_click()
    view |> element("#delete-session-cancel") |> render_click()
    refute has_element?(view, "#delete-session-modal")
    assert TraceSessionQueries.get(id)

    view |> element("#session-delete") |> render_click()
    view |> element("#delete-session-modal #delete-session-confirm") |> render_click()

    assert %{"info" => _} = assert_redirect(view, ~p"/node/#{@node_name}/tracing", 2_000)
    refute TraceSessionQueries.get(id)
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
    view |> element("#session-start") |> render_click()
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

  test "inserts traced calls live, newest first", %{conn: conn} do
    %{id: id} = start!(%{capture: :args, budget: 1_000})
    view = open(conn, id)

    assert has_element?(view, "#log-live")
    refute has_element?(view, "#log-duration")

    call_traced!(2, 2)
    flush_log(view)

    assert row_ids(view) == ["entry-3", "entry-2", "entry-1", "entry-0"]
    assert has_element?(view, "#entry-2 [role=img][aria-label=call]")
    assert has_element?(view, "#entry-2", "(~D[2024-01-01])")
    assert has_element?(view, "#entry-2 a[href*='/processes/']")
    assert has_element?(view, "#log-footer", "All 2 traces shown")
  end

  test "skips a live entry the first page already holds", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)
    started = %{seq: 1, kind: :started, origin: :mcp, at: 0}

    send(view.pid, {:session_entries, Tracer.active(), [started]})
    flush_log(view)

    assert has_element?(view, "#entry-1", "by UI")
    refute has_element?(view, "#entry-1", "by MCP")
  end

  test "keeps only the newest 200 rows", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(250, 250)
    flush_log(view)

    assert length(row_ids(view)) == 200
    assert has_element?(view, "#entry-251")
    refute has_element?(view, "#entry-51")
    assert has_element?(view, "#log-footer", "Newest 200 of 250 traces")
    assert has_element?(view, "#log-older")
  end

  test "counts new traces while paused and catches up on resume", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    view |> element("#log-pause") |> render_click()
    call_traced!(2, 2)
    flush_log(view)

    refute has_element?(view, "#log-live")
    refute has_element?(view, "#entry-2")
    assert has_element?(view, "#log-new-count", "2 new events")

    view |> element("#log-resume") |> render_click()
    render_async(view)

    assert has_element?(view, "#entry-3")
    assert has_element?(view, "#log-live")
    refute has_element?(view, "#log-paused")
  end

  test "loads older entries and pauses a running view", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(150, 150)

    view = open(conn, id)
    refute has_element?(view, "#entry-0")
    assert has_element?(view, "#log-footer", "Newest 100 of 150 traces")

    view |> element("#log-older") |> render_click()
    render_async(view)

    assert has_element?(view, "#entry-0")
    assert has_element?(view, "#log-paused")
    refute has_element?(view, "#log-older")
    assert has_element?(view, "#log-footer", "All 150 traces shown")
  end

  test "marks where an unsaved session evicted older events", %{conn: conn} do
    %{id: id} = start!(%{max_events: 501})
    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: 501}, [%{kind: :stopped}]}, 2_000

    view = open(conn, id)
    load_all_older(view)

    assert Enum.take(row_ids(view), -4) == ["entry-3", "entry-evicted-2", "entry-1", "entry-0"]
    assert has_element?(view, "#log-footer", "All 500 kept events shown · 501 traced")
  end

  test "shows a duration for returns", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    call_traced!(1, 2)

    view = open(conn, id)

    assert has_element?(view, "#log-duration")
    assert has_element?(view, "#entry-3 [aria-label=return]")
    assert has_element?(view, "#entry-3 td:last-child", ~r/^\s*\d+\.\d{2} ms\s*$/)
  end

  test "shows the configured, started and stopped entries", %{conn: conn} do
    %{id: id} = start!()
    :ok = Tracer.stop(:ui)
    _ = :sys.get_state(Tracer)

    view = open(conn, id)

    assert has_element?(view, "#entry-0", "Configured")
    assert has_element?(view, "#entry-0", "by UI")
    assert has_element?(view, "#entry-1", "Started")
    assert has_element?(view, "#entry-2", "Stopped")
    assert has_element?(view, "#entry-2", "by UI")
  end

  test "does not link pids of another node's session", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(1, 1)
    Fakes.connect_node!(Fakes.node_session(node: :other@nohost, node_name: "other@nohost"))

    {:ok, view, _html} = live(conn, ~p"/node/other@nohost/tracing/#{id}")
    render_async(view)

    assert has_element?(view, "#entry-2", Formatters.pid(self()))
    refute has_element?(view, "#entry-2 a")
  end

  test "shows a call whose arguments the budget truncated whole", %{conn: conn} do
    %{id: id} = start!(%{capture: :args, budget: 0})
    view = open(conn, id)

    call_traced!(1, 1)
    flush_log(view)

    assert has_element?(view, "#entry-2", "leap_year?/1")
  end

  test "re-renders the held rows when the session is reconfigured", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    call_traced!(1, 2)
    view = open(conn, id)
    :ok = Tracer.stop(:ui)

    {:ok, _session} = configure(%{return_trace: false})
    _ = :sys.get_state(Tracer)
    render_async(view)

    refute has_element?(view, "#log-duration")
    refute has_element?(view, "#entry-3 td:nth-child(4)")
  end

  test "counts only the trace rows the stream keeps", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(100, 100)
    view = open(conn, id)
    :ok = Tracer.stop(:ui)
    {:ok, _session} = Tracer.start(:ui)

    call_traced!(150, 250)
    flush_log(view)

    assert has_element?(view, "#log-footer", "Newest 198 of 250 traces")
  end

  test "offers a retry when the events fail to load", %{conn: conn} do
    %{id: id} = saved_inactive!()
    view = open(conn, id)
    {:ok, session, :saved} = Tracer.session(id)
    {:ok, _row} = Voyager.Actions.TraceSessions.delete(id)

    send(view.pid, {:session_activated, session})
    render_async(view)

    assert has_element?(view, "#log-resume")
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

  defp start!(overrides \\ %{}) do
    session = create!()
    {:ok, _session} = configure(overrides)
    {:ok, _session} = Tracer.start(:ui)
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    session
  end

  defp call_traced!(calls, traces) do
    for _ <- 1..calls, do: Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: ^traces}, _entries}, 2_000
  end

  # The broadcast reaches the view before the Tracer handles its next message.
  defp flush_log(view) do
    _ = :sys.get_state(Tracer)
    send(view.pid, :flush_log)
    render(view)
  end

  defp load_all_older(view) do
    if has_element?(view, "#log-older") do
      view |> element("#log-older") |> render_click()
      render_async(view)
      load_all_older(view)
    end
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#session-log-rows > tr")
    |> LazyHTML.attribute("id")
  end

  defp create!(opts \\ []) do
    {:ok, session} = Tracer.create(:ui, opts)
    session
  end

  defp saved_inactive! do
    session = create!(save: true)
    {:ok, _session} = configure()
    create!()
    session
  end

  defp configure(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          pids: [Voyager.Pid.format(self(), :distribution)],
          max_events: 1_000
        },
        overrides
      )

    Tracer.configure(Node.self(), attrs, :ui)
  end

  defp open(conn, id) do
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{id}")
    render_async(view)
    view
  end

  # A stop lands as a broadcast once the remote tracer's done message reaches the Tracer.
  defp settle(view) do
    render_async(view)
    _ = :sys.get_state(Tracer)
  end
end
