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
    assert has_element?(view, "#session-edit[aria-disabled]")

    assert view
           |> element("#session-edit-tip-portal")
           |> render() =~ "Stop the session"

    refute has_element?(view, "#session-resume")
    refute has_element?(view, "#session-unload")

    view
    |> element("#session-stop")
    |> render_click()

    assert has_element?(
             view,
             "#stop-session-modal span.font-mono.text-base-content",
             "Date.leap_year?/1"
           )

    assert has_element?(view, "#stop-session-modal", "No traces are kept")

    view
    |> element("#stop-session-modal-cancel")
    |> render_click()

    refute has_element?(view, "#stop-session-modal")
    assert has_element?(view, "#session-status[data-tone=running]")

    view
    |> element("#session-stop")
    |> render_click()

    view
    |> element("#stop-session-modal-confirm")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-resume:not([disabled])")
    assert has_element?(view, "#session-unload:not([disabled])")
    assert has_element?(view, "#session-edit:not([aria-disabled])")
    refute has_element?(view, "#session-stop")
  end

  test "says one trace is kept when stopping a single trace", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(1, 1)
    put_queued(view)

    view
    |> element("#session-stop")
    |> render_click()

    assert has_element?(view, "#stop-session-modal", "Its 1 trace is kept")
  end

  test "closes the stop confirmation once the run ends on its own", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)
    view = open(conn, id)

    view
    |> element("#session-stop")
    |> render_click()

    assert has_element?(view, "#stop-session-modal")

    :ok = Tracer.stop(:ui)
    render_async(view)

    refute has_element?(view, "#stop-session-modal")
  end

  test "ignores a stop that arrives after the run has ended", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)
    view = open(conn, id)

    :ok = Tracer.stop(:ui)
    settle(view)

    render_click(view, "stop", %{})

    refute has_element?(view, "#stop-session-modal")
  end

  test "ignores a stop pushed before the session has loaded", %{conn: conn} do
    session = create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)
    :ok = :sys.suspend(Tracer)
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{session.id}")

    render_click(view, "stop", %{})

    refute has_element?(view, "#stop-session-modal")
    :ok = :sys.resume(Tracer)
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

    assert has_element?(view, "#session-resume[aria-disabled]")
    assert has_element?(view, "#session-edit[aria-disabled]")
    assert has_element?(view, "#session-unload:not([disabled])")

    assert view
           |> element("#session-run-tip-portal")
           |> render() =~ "other@localhost"
  end

  test "shows the empty state for an unconfigured session", %{conn: conn} do
    %{id: id} = create!()

    view = open(conn, id)

    assert has_element?(view, "#session-start[disabled]")
    refute has_element?(view, "#session-run-tip")
    assert has_element?(view, "#session-empty")
    assert has_element?(view, "#session-set-parameters:not([disabled])")
    assert has_element?(view, "#session-chip-storage", "Not saved")
    refute has_element?(view, "#session-edit")
  end

  test "starts a configured session", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()

    view = open(conn, id)

    assert has_element?(view, "#session-edit:not([aria-disabled])")
    refute has_element?(view, "#session-empty")
    assert has_element?(view, "#log-footer", "No traces yet")
    assert has_element?(view, "#log-search[disabled]")

    view
    |> element("#session-start:not([disabled])")
    |> render_click()

    settle(view)

    assert has_element?(view, "#session-stop")
  end

  test "opens the parameters form on an unconfigured session, filled with the defaults", %{
    conn: conn
  } do
    %{id: id} = create!()
    view = open(conn, id)
    refute has_element?(view, "#config-modal")

    view
    |> element("#session-set-parameters")
    |> render_click()

    assert has_element?(view, "#config_processes_all[checked]")
    assert has_element?(view, "#config_max_events[value='10000']")
    assert has_element?(view, "#config_max_time[value='300']")
    assert has_element?(view, "#config_max_time_unit-s-option input[checked]")

    view
    |> element("#config-cancel")
    |> render_click()

    refute has_element?(view, "#config-modal")
  end

  test "closes the parameters form from its close button and from outside it", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    for close <- ["#config-close", "#config-backdrop"] do
      view
      |> element("#session-set-parameters")
      |> render_click()

      view
      |> element(close)
      |> render_click()

      refute has_element?(view, "#config-modal")
    end

    assert %{config: nil} = Tracer.active()
  end

  test "ignores a save sent after the form was cancelled", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> element("#config-cancel")
    |> render_click()

    render_hook(view, "save-config", %{"config" => %{"module" => "Date", "max_events" => "5"}})
    settle(view)

    refute has_element?(view, "#config-modal")
    assert %{config: nil} = Tracer.active()
  end

  test "keeps the form closed until a cancelled save finishes", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    :ok = :sys.suspend(Tracer)

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "1"})
    |> put_submitter("#config-save")
    |> render_submit()

    view
    |> element("#config-cancel")
    |> render_click()

    view
    |> element("#session-set-parameters")
    |> render_click()

    refute has_element?(view, "#config-modal")

    :ok = :sys.resume(Tracer)
    settle(view)

    refute has_element?(view, "#config-modal")
    assert %{function: "leap_year?"} = Tracer.active().config
  end

  test "ignores a second save while the first one runs", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    :ok = :sys.suspend(Tracer)

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "1"})
    |> put_submitter("#config-save")
    |> render_submit()

    view
    |> form("#config-form", config: %{max_events: "5"})
    |> render_submit()

    :ok = :sys.resume(Tracer)
    settle(view)

    assert %{function: "leap_year?", max_events: 10_000} = Tracer.active().config
  end

  test "saves a time limit in milliseconds and reopens it in milliseconds", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Date", max_time: "1500", max_time_unit: "ms"})
    |> put_submitter("#config-save")
    |> render_submit()

    settle(view)

    assert %{max_time_ms: 1_500} = Tracer.active().config

    view
    |> element("#session-edit")
    |> render_click()

    assert has_element?(view, "#config_max_time[value='1500']")
    assert has_element?(view, "#config_max_time_unit-ms-option input[checked]")
  end

  test "saves the parameters from the form and closes it", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "1"})
    |> put_submitter("#config-save")
    |> render_submit()

    settle(view)

    refute has_element?(view, "#config-modal")
    assert has_element?(view, "#session-start:not([disabled])")

    assert %{
             module: "Elixir.Date",
             function: "leap_year?",
             arity: 1,
             processes: :all,
             max_events: 10_000,
             max_rate: 1_000,
             max_time_ms: 300_000
           } = Tracer.active().config
  end

  test "starts the session from the form", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "1"})
    |> put_submitter("#config-start")
    |> render_submit()

    settle(view)

    refute has_element?(view, "#config-modal")
    assert has_element?(view, "#session-stop")
  end

  test "keeps the form open with the reason a start failed on its field", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "2"})
    |> put_submitter("#config-start")
    |> render_submit()

    settle(view)

    assert has_element?(view, "#config_function.input-error")
    refute has_element?(view, "#session-stop")
  end

  test "shows a missing module at the foot of the form, not on its function", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Voyager.NoSuchModule", function: "run"})
    |> put_submitter("#config-start")
    |> render_submit()

    settle(view)

    assert has_element?(view, "#config-error")
    refute has_element?(view, "#config_function.input-error")
    refute has_element?(view, "#session-stop")
  end

  test "validates the form as it changes", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{module: "Enum", function: "map"})
    |> render_change()

    assert has_element?(view, "#config_module.input-error")

    view
    |> form("#config-form", config: %{processes: "pids", module: "Enum", function: "map"})
    |> render_change()

    refute has_element?(view, "#config_module.input-error")
    assert has_element?(view, "#config_pids.input-error")
  end

  test "keeps fields unmarked until they are used", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    |> form("#config-form", config: %{processes: "pids"})
    |> render_change(%{config: %{_unused_module: "", _unused_pids: ""}})

    refute has_element?(view, "#config_module.input-error")
    refute has_element?(view, "#config_pids.input-error")
  end

  test "keeps the typed pids while another process set is picked", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    changes = [
      %{processes: "pids"},
      %{pids: "<0.1.0>"},
      %{processes: "all"},
      %{processes: "pids"}
    ]

    for change <- changes do
      view
      |> form("#config-form", config: change)
      |> render_change()
    end

    assert has_element?(view, "#config_pids[value='<0.1.0>']")
  end

  test "edits the parameters of a stopped session, adding no row when nothing changed", %{
    conn: conn
  } do
    %{id: id} = create!()
    {:ok, _session} = configure()
    view = open(conn, id)
    rows = row_ids(view)

    view
    |> element("#session-edit")
    |> render_click()

    assert has_element?(view, "#config_module[value='Date']")

    view
    |> form("#config-form")
    |> put_submitter("#config-save")
    |> render_submit()

    settle(view)

    refute has_element?(view, "#config-modal")
    assert row_ids(view) == rows
  end

  test "puts a refusal from the node on the field it names", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    view
    # The alias makes the atom exist, so the node checks whether the module is loaded.
    |> form("#config-form", config: %{module: inspect(Nope.Missing), function: "run"})
    |> put_submitter("#config-start")
    |> render_submit()

    settle(view)

    assert has_element?(view, "#config_module.input-error")

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, :normal}

    view
    |> form("#config-form",
      config: %{module: "Date", function: "leap_year?", arity: "1", processes: "pids"}
    )
    |> render_change()

    view
    |> form("#config-form", config: %{pids: Voyager.Pid.format(dead, :distribution)})
    |> put_submitter("#config-start")
    |> render_submit()

    settle(view)

    assert has_element?(view, "#config_pids.input-error")
    refute has_element?(view, "#config_module.input-error")
    refute has_element?(view, "#session-stop")
  end

  test "shows a failure that names no field at the foot of the form", %{conn: conn} do
    %{id: id} = create!()
    {:ok, _session} = configure()
    view = open(conn, id)

    view
    |> element("#session-edit")
    |> render_click()

    {:ok, _session} = Tracer.start(:ui)

    view
    |> form("#config-form", config: %{max_events: "50"})
    |> put_submitter("#config-save")
    |> render_submit()

    settle(view)

    assert has_element?(view, "#config-error", "A tracing session is running")
    assert Tracer.active().config.max_events == 1_000
  end

  test "flashes why a start failed once the form was cancelled", %{conn: conn} do
    %{id: id} = create!()
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    :ok = :sys.suspend(Tracer)

    view
    |> form("#config-form", config: %{module: "Date", function: "leap_year?", arity: "2"})
    |> put_submitter("#config-start")
    |> render_submit()

    view
    |> element("#config-cancel")
    |> render_click()

    :ok = :sys.resume(Tracer)
    settle(view)

    refute has_element?(view, "#config-modal")
    assert has_element?(view, "#flash-error", "No loaded function matches")
  end

  test "closes the form and ignores its changes and save once the session leaves the tracer", %{
    conn: conn
  } do
    %{id: id} = create!(save: true)
    view = open(conn, id)

    view
    |> element("#session-set-parameters")
    |> render_click()

    %{id: replacing} = create!()
    render_async(view)

    refute has_element?(view, "#config-modal")

    render_hook(view, "validate-config", %{"config" => %{"module" => "Date"}})

    refute has_element?(view, "#config-modal")

    render_hook(view, "save-config", %{
      "config" => %{"module" => "Date", "max_events" => "5"},
      "action" => "start"
    })

    settle(view)

    assert %{id: ^replacing, config: nil, status: :idle} = Tracer.active()
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

    assert has_element?(view, "#entry-0-changes", ~r/^\s*Date\.leap_year\?\/1\s*$/)

    {:ok, _session} = configure(%{scope: :local, max_events: nil, max_time_ms: 90_000})
    render_async(view)

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

  test "replaces an unsaved session in the tracer only once confirmed", %{conn: conn} do
    %{id: id} = saved_inactive!()
    {:ok, _session} = configure()
    view = open(conn, id)

    view
    |> element("#session-load")
    |> render_click()

    view
    |> element("#load-session-modal-cancel")
    |> render_click()

    refute has_element?(view, "#load-session-modal")
    assert has_element?(view, "#session-load")

    view
    |> element("#session-load")
    |> render_click()

    view
    |> element("#load-session-modal-confirm")
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

    assert has_element?(view, "#delete-session-modal", "No traces are deleted.")

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

  test "flashes the storage limit instead of starting a saved session with no storage left",
       %{conn: conn} do
    {:ok, _} = Voyager.Settings.put(:trace_storage_limit_mb, 0)
    %{id: id} = create!(save: true)
    {:ok, _session} = configure()

    view = open(conn, id)

    view
    |> element("#session-start")
    |> render_click()

    settle(view)

    assert has_element?(view, "#flash-error", "Saved sessions use all their storage")
    assert has_element?(view, "#session-start")
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

    assert has_element?(
             view,
             "#stat-storage [tabindex='0'][aria-describedby='stat-storage-tip-tip']"
           )

    refute has_element?(view, "#stat-events [tabindex]")
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

  test "holds count-only updates until the throttle flushes them", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(3, 3)
    _ = :sys.get_state(Tracer)
    assert has_element?(view, "#stat-events .tabular-nums", "0")

    put_queued(view)
    assert has_element?(view, "#stat-events .tabular-nums", "3")
  end

  test "times the rate by the traces' own timestamps", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, session, [trace]}, 2_000
    _ = :sys.get_state(Tracer)
    send(view.pid, :tick)

    spaced = for n <- 1..9, do: %{trace | seq: trace.seq + n, at: trace.at + n * 100_000}
    send(view.pid, {:session_entries, session, spaced})
    send(view.pid, :tick)
    assert has_element?(view, "#stat-rate", "10")

    send(view.pid, :tick)
    burst = for n <- 10..11, do: %{trace | seq: trace.seq + n, at: trace.at + 60_000_000 + n}
    send(view.pid, {:session_entries, session, burst})
    send(view.pid, :tick)
    assert has_element?(view, "#stat-rate", "2")
  end

  test "does not read the rest of a burst split across ticks as a faster rate", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, session, [trace]}, 2_000
    _ = :sys.get_state(Tracer)
    send(view.pid, :tick)

    rest = for n <- 1..20, do: %{trace | seq: trace.seq + n, at: trace.at + n * 1_000}
    send(view.pid, {:session_entries, session, rest})
    send(view.pid, :tick)
    assert has_element?(view, "#stat-rate .tabular-nums", "22")
  end

  test "restarts the rate samples with a new run", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    call_traced!(3, 3)
    _ = :sys.get_state(Tracer)
    send(view.pid, :tick)
    assert has_element?(view, "#stat-rate .tabular-nums", "3")

    :ok = Tracer.stop(:ui)
    settle(view)
    {:ok, _session} = Tracer.start(:ui)
    settle(view)

    assert has_element?(view, "#stat-rate .tabular-nums", "0")
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
