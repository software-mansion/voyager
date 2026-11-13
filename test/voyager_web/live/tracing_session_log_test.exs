defmodule VoyagerWeb.TracingSessionLogTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture
  import Voyager.TestUtils, only: [reset_term_syntax: 1]

  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Fakes
  alias Voyager.Services.TermSyntax
  alias Voyager.Services.Tracer
  alias VoyagerWeb.Formatters

  setup :setup_tracer

  test "inserts traced calls live, newest first", %{conn: conn} do
    %{id: id} = start!(%{capture: :args, budget: 1_000})
    view = open(conn, id)

    assert has_element?(view, "#log-live")
    refute has_element?(view, "#log-duration")
    assert has_element?(view, "#session-log th", "Arguments / result")

    call_traced!(2, 2)
    flush_log(view)

    assert row_ids(view) == ["entry-3", "entry-2", "entry-1", "entry-0"]
    assert has_element?(view, "#entry-2 [role=img][aria-label=Call]")
    assert has_element?(view, "#entry-2", "(~D[2024-01-01])")
    assert has_element?(view, "#entry-2 a[href*='/processes/']")
    assert has_element?(view, "#entry-2[phx-mounted]")
    assert has_element?(view, "#log-footer", "All 2 traces shown")
  end

  test "holds live rows and the session's counts until the browser acks the last flush", %{
    conn: conn
  } do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(1, 1)
    flush_log(view)
    assert_push_event(view, "log-flushed", %{})

    call_traced!(1, 2)
    _ = :sys.get_state(Tracer)
    send(view.pid, :flush)
    refute has_element?(view, "#entry-3")
    assert has_element?(view, "#stat-events .tabular-nums", ~r/^\s*1\s*$/)
    assert has_element?(view, "#tracing-indicator-count", ~r/^\s*1\s*$/)

    flush_log(view)
    assert has_element?(view, "#entry-3")
    assert has_element?(view, "#stat-events .tabular-nums", ~r/^\s*2\s*$/)
    assert has_element?(view, "#tracing-indicator-count", ~r/^\s*2\s*$/)
  end

  test "skips a live entry the first page already holds", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)
    started = %{seq: 1, kind: :started, origin: :mcp, at: 0}

    send(view.pid, {:session_entries, Tracer.active(), [started]})
    flush_log(view)

    assert has_element?(view, "#entry-1", "Started")
    refute has_element?(view, "#entry-1", "by MCP")
  end

  test "counts a single dropped event in the singular", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)
    dropped = %{seq: 2, kind: :dropped, origin: nil, count: 1, at: 0}

    send(view.pid, {:session_entries, Tracer.active(), [dropped]})
    flush_log(view)

    assert has_element?(view, "#entry-2", "1 event dropped")
  end

  test "keeps only the newest 200 rows", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    for n <- 1..5 do
      call_traced!(50, 50 * n)
      flush_log(view)
    end

    assert length(row_ids(view)) == 200
    assert has_element?(view, "#entry-251")
    refute has_element?(view, "#entry-51")
    assert has_element?(view, "#log-footer", "Newest 200 of 250 traces")
    assert has_element?(view, "#log-older")
  end

  test "counts new traces while paused and catches up on resume", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    view
    |> element("#log-pause")
    |> render_click()

    call_traced!(2, 2)
    _ = :sys.get_state(Tracer)
    refute has_element?(view, "#log-new-count")

    flush_log(view)

    refute has_element?(view, "#log-live")
    refute has_element?(view, "#entry-2")
    assert has_element?(view, "#log-resume #log-new-count", "2 new")
    assert has_element?(view, "#log-footer", "0 of 2 traces shown")

    view
    |> element("#log-resume")
    |> render_click()

    render_async(view)

    assert has_element?(view, "#entry-3")
    assert has_element?(view, "#log-live")
    refute has_element?(view, "#log-paused")
  end

  test "streams the newest 50 entries a flush holds, and loads the ones it dropped older",
       %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    for n <- 1..5 do
      call_traced!(80, 80 * n)
      flush_log(view)
    end

    assert row_ids(view) == entry_ids(401..352//-1)
    assert has_element?(view, "#log-footer", "Newest 50 of 400 traces")

    view
    |> element("#log-older")
    |> render_click()

    render_async(view)

    assert row_ids(view) == entry_ids(401..252//-1)
  end

  test "offers the traces a burst on a fresh session dropped as older", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(120, 120)
    flush_log(view)

    assert row_ids(view) == entry_ids(121..72//-1)
    assert has_element?(view, "#log-footer", "Newest 50 of 120 traces")

    load_all_older(view)

    assert row_ids(view) == entry_ids(121..0//-1)
    refute has_element?(view, "#log-older")
    assert has_element?(view, "#log-footer", "All 120 traces shown")
  end

  test "loads older entries and pauses a running view", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(150, 150)

    view = open(conn, id)
    refute has_element?(view, "#entry-0")
    assert has_element?(view, "#log-footer", "Newest 100 of 150 traces")

    view
    |> element("#log-older")
    |> render_click()

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

  test "marks every gap the eviction left between runs", %{conn: conn} do
    %{id: id} = start!(%{max_events: 501})
    call_traced!(2, 2)
    :ok = Tracer.stop(:ui)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}, 2_000

    {:ok, _session} = Tracer.start(:ui)
    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}, 2_000

    view = open(conn, id)
    load_all_older(view)

    assert Enum.take(row_ids(view), -7) ==
             ~w(entry-7 entry-evicted-6 entry-5 entry-4 entry-evicted-2 entry-1 entry-0)
  end

  test "ignores a pause while a reload replaces the rows", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    view
    |> element("#log-pause")
    |> render_click()

    :sys.suspend(Tracer)

    view
    |> element("#log-resume")
    |> render_click()

    view
    |> element("#log-pause")
    |> render_click()

    :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#log-live")
    refute has_element?(view, "#log-paused")
  end

  test "shows a duration for returns", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    call_traced!(1, 2)

    view = open(conn, id)

    assert has_element?(view, "#log-duration")
    assert has_element?(view, "#entry-3 [aria-label=Return]")
    assert has_element?(view, "#entry-3 td:last-child", ~r/^\s*(\d+ µs|\d+\.\d{2} ms)\s*$/)
    assert has_element?(view, "#entry-3 .text-code-special", "true")
    refute has_element?(view, "#entry-3[phx-mounted]")
  end

  test "shows the configured, started and stopped entries", %{conn: conn} do
    %{id: id} = start!()
    :ok = Tracer.stop(:mcp)
    _ = :sys.get_state(Tracer)

    view = open(conn, id)

    assert has_element?(view, "#entry-0", "Configured")
    refute has_element?(view, "#entry-0", "by UI")
    assert has_element?(view, "#entry-1", "Started")
    assert has_element?(view, "#entry-1 td[title]")
    assert has_element?(view, "#entry-2", "Stopped")
    assert has_element?(view, "#entry-2", "by MCP")
  end

  test "colours bare atoms in Erlang syntax", %{conn: conn} do
    reset_term_syntax(%{})
    {:ok, :erlang} = TermSyntax.save_setting(:erlang)
    %{id: id} = start!(%{capture: :args, budget: 1_000})
    call_traced!(1, 1)

    view = open(conn, id)

    assert has_element?(view, "#entry-2 .text-code-atom", "calendar")
  end

  test "cuts a large term in the tooltip and names the process", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    view = open(conn, id)

    returned = %{
      seq: 2,
      kind: :trace,
      type: :return,
      at: 0,
      pid: self(),
      process: :my_server,
      mfa: {Date, :leap_year?, 1},
      value: Map.new(1..100, &{&1, String.duplicate("x", 80)})
    }

    send(view.pid, {:session_entries, Tracer.active(), [returned]})
    flush_log(view)

    tip = view |> element("#entry-2-term-content") |> render()
    strings = tip |> String.split("text-code-string") |> length()

    assert tip =~ "Date"
    assert tip =~ "my_server"
    assert tip =~ "…"
    assert strings in 2..17
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

  test "links the pids a session traced before it moved to another node", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(1, 1)
    :ok = Tracer.stop(:ui)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}, 2_000

    {:ok, _session} =
      Tracer.configure(
        :other@nohost,
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          processes: :all,
          max_events: 1_000
        },
        :ui
      )

    view = open(conn, id)

    assert has_element?(view, "#entry-2 a[href*='/processes/']")
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
    flush_log(view)

    for traces <- [150, 200, 250] do
      call_traced!(50, traces)
      flush_log(view)
    end

    assert has_element?(view, "#log-footer", "Newest 198 of 250 traces")
  end

  test "offers a retry when the events fail to load", %{conn: conn} do
    %{id: id} = saved_inactive!()
    view = open(conn, id)
    {:ok, session, :saved} = Tracer.session(id)
    {:ok, _row} = TraceSessionActions.delete(id)

    send(view.pid, {:session_activated, session})
    render_async(view)

    assert has_element?(view, "#log-resume")
  end

  test "flashes when older entries fail to load", %{conn: conn} do
    %{id: id} = start!(%{}, save: true)
    call_traced!(150, 150)
    :ok = Tracer.stop(:ui)
    _ = :sys.get_state(Tracer)
    view = open(conn, id)
    {:ok, _row} = TraceSessionActions.delete(id)

    view
    |> element("#log-older")
    |> render_click()

    render_async(view)

    assert has_element?(view, "#flash-error", "Could not load older events.")
  end

  defp entry_ids(seqs), do: Enum.map(seqs, &"entry-#{&1}")

  defp load_all_older(view) do
    if has_element?(view, "#log-older") do
      view
      |> element("#log-older")
      |> render_click()

      render_async(view)
      load_all_older(view)
    end
  end
end
