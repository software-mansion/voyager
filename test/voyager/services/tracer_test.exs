defmodule Voyager.Services.TracerTest do
  # async: false because these tests swap the global erpc impl and share the app's Tracer.
  use Voyager.DataCase, async: false

  import ExUnit.CaptureLog

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceEvent
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    # The stop's DB write must land before the sandbox owner exits.
    on_exit(fn ->
      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)
      Writer.flush()
    end)

    {:ok, session} = Tracer.create(:ui)
    %{session: session}
  end

  test "creates and closes the active session", %{session: %{id: id}} do
    assert_receive {:session_activated, %{id: ^id, origin: :ui, save: false, status: :idle}}

    assert {:ok, %{id: new_id, origin: :mcp, save: true}} = Tracer.create(:mcp, save: true)
    refute new_id == id
    assert %{id: ^new_id} = Tracer.active()
    assert {:ok, %{entries: [], truncated?: false}} = Tracer.entries(new_id)

    assert :ok = Tracer.close()
    assert_receive {:session_closed, ^new_id}
    assert nil == Tracer.active()
    assert {:ok, %{entries: []}} = Tracer.entries(new_id)
    assert {:error, :not_found} = Tracer.entries(id)
    assert {:error, :no_session} = configure()
    assert {:error, :no_session} = Tracer.start(:ui)
  end

  test "logs the configure, the events and the stop with their origins" do
    assert {:ok, %{id: id, status: :idle}} = configure(%{}, :mcp)

    assert_receive {:session_entries, %{id: ^id},
                    [%{seq: 0, kind: :configured, origin: :mcp, node: node, config: _config}]}

    assert node == Node.self()

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start(:ui)

    assert_receive {:session_entries, %{status: :running},
                    [%{seq: 1, kind: :started, origin: :ui}]}

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, %{traces: 1},
                    [%{seq: 2, kind: :trace, type: :call, mfa: {Date, :leap_year?, 1}}]},
                   1_000

    assert :ok = Tracer.stop(:mcp)

    assert_receive {:session_entries,
                    %{status: :stopped, stop_reason: :stopped, stopped_at: %DateTime{}},
                    [
                      %{
                        seq: 3,
                        kind: :stopped,
                        origin: :mcp,
                        reason: :stopped,
                        traces: 1,
                        dropped: 0
                      }
                    ]}

    assert %{id: ^id, status: :stopped} = Tracer.active()

    assert {:ok,
            %{
              entries: [
                %{kind: :stopped},
                %{kind: :trace},
                %{kind: :started},
                %{kind: :configured}
              ],
              truncated?: false
            }} = Tracer.entries(id)

    assert {:ok, %{entries: [%{seq: 2}, %{seq: 1}]}} = Tracer.entries(id, before: 3, limit: 2)

    assert {:ok, %{entries: [%{seq: 1}, %{seq: 2}]}} =
             Tracer.entries(id, since: 1, order: :asc, limit: 2)

    assert {:ok, %{entries: [%{seq: 3}, %{seq: 2}]}} = Tracer.entries(id, since: 1, limit: 2)
    assert {:ok, %{entries: [], truncated?: false}} = Tracer.entries(id, since: 4, order: :asc)

    assert {:ok, %{entries: [%{seq: 3}, _, _, _], truncated?: false}} =
             Tracer.entries(id, before: 1_000)
  end

  test "publishes the session status with each change" do
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())

    assert {:ok, _session} = configure()
    assert_receive {:session_updated, %{status: :idle, config: %Config{}}}
    assert {:ok, _session} = Tracer.start(:ui)
    assert_receive {:session_updated, %{status: :running, traces: 0}}

    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_updated, %{status: :running, traces: 1}}, 1_000

    assert :ok = Tracer.stop(:ui)
    assert_receive {:session_updated, %{status: :stopped, traces: 1}}
    assert :ok = Tracer.close()
    assert_receive {:session_updated, nil}
  end

  for save <- [false, true] do
    test "a configured entry carries the config it replaced, save: #{save}" do
      assert {:ok, %{id: id}} = Tracer.create(:ui, save: unquote(save))
      assert {:ok, %{config: first}} = configure()
      assert {:ok, %{config: second}} = configure(%{max_events: 5})

      assert {:ok, %{entries: [%{previous: ^first, config: ^second}, %{previous: nil}]}} =
               Tracer.entries(id)
    end
  end

  test "saves a saved session's log as it is appended, reading back what was broadcast" do
    assert {:ok, %{id: id}} = Tracer.create(:mcp, save: true)
    assert id > 0
    assert %{status: :idle, origin: :mcp} = TraceSessionQueries.get(id)

    assert {:ok, _session} = configure()
    assert_receive {:session_entries, _session, [configured]}
    assert {:ok, _session} = Tracer.start(:ui)
    assert_receive {:session_entries, _session, [started]}
    Writer.flush()
    assert %{status: :running, started_at: %DateTime{}} = TraceSessionQueries.get(id)

    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: 1}, [%{kind: :trace} = trace]}, 1_000
    assert :ok = Tracer.stop(:mcp)
    assert_receive {:session_entries, _session, [%{kind: :stopped} = stopped]}
    Writer.flush()

    assert %{status: :stopped, stop_reason: :stopped, traces: 1, bytes: bytes, node: node} =
             TraceSessionQueries.get(id)

    assert bytes > 0
    assert node == Atom.to_string(Node.self())

    assert {:ok, %{entries: entries, truncated?: false}} = Tracer.entries(id)
    assert entries == [stopped, trace, started, configured]
    assert %{mfa: {Date, :leap_year?, 1}, args: [~D[2024-01-01]]} = trace

    assert {:ok, %{entries: [%{seq: 1}, %{seq: 2}]}} =
             Tracer.entries(id, since: 1, order: :asc, limit: 2)

    assert {:ok, %{entries: [%{seq: 1}]}} = Tracer.entries(id, before: 2, limit: 1)
  end

  test "stops a saved run once its entries pass the storage limit" do
    {:ok, _} = Voyager.Settings.put(:trace_storage_limit_mb, 0)
    assert {:ok, %{id: id}} = Tracer.create(:mcp, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, _session, [%{kind: :stopped, reason: :storage_limit}]},
                   1_000

    Writer.flush()
    assert %{status: :stopped, stop_reason: :storage_limit} = TraceSessionQueries.get(id)
  end

  test "keeps an unsaved session out of the database" do
    assert {:ok, %{id: id}} = configure(%{max_events: 1})
    assert id < 0
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}

    assert TraceSessionQueries.all() == []
    assert {:ok, %{entries: [%{kind: :stopped} | _]}} = Tracer.entries(id)
  end

  test "loads a saved session and resumes it from its config" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}
    assert {:ok, _session} = Tracer.create(:ui)

    assert {:ok, %{id: ^id, status: :stopped, seq: 4, traces: 1, node: node, config: config}} =
             Tracer.load(id)

    assert_receive {:session_activated, %{id: ^id}}
    assert node == Node.self()
    assert %Config{module: "Elixir.Date", max_events: 1} = config
    assert %{id: ^id} = Tracer.active()

    assert {:ok, %{status: :running}} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: 2}, [%{seq: 6, kind: :stopped}]}
    Writer.flush()
    assert %{traces: 2} = TraceSessionQueries.get(id)
  end

  test "loads a session whose saved status stayed running as interrupted" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}
    assert {:ok, _session} = Tracer.create(:ui)
    Writer.flush()
    Repo.update_all(TraceSession, set: [status: :running, stop_reason: nil])

    assert {:ok, %{id: ^id, status: :stopped, stop_reason: :interrupted}} = Tracer.load(id)
    assert {:ok, %{status: :running}} = Tracer.start(:ui)
  end

  test "loads a saved session that was never configured" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = Tracer.create(:ui)
    assert {:ok, %{id: ^id, node: nil, config: nil}} = Tracer.load(id)
  end

  test "refuses to load a missing session or while running" do
    assert {:error, :not_found} = Tracer.load(0)
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert {:error, :busy} = Tracer.load(id)
  end

  test "deletes a saved session unless it runs" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert {:error, :busy} = Tracer.delete(id)

    assert :ok = Tracer.stop(:ui)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}
    assert {:ok, _row} = Tracer.delete(id)
    assert_receive {:session_closed, ^id}
    assert nil == Tracer.active()
    assert {:error, :not_found} = Tracer.entries(id)
    assert {:error, :not_found} = Tracer.delete(id)
  end

  test "leaves an unsaved active session intact on delete" do
    assert {:ok, %{id: id}} = Tracer.create(:ui)
    assert {:ok, %{id: ^id, status: :idle}} = configure()

    assert {:error, :not_found} = Tracer.delete(id)

    refute_receive {:session_closed, ^id}, 100
    assert %{id: ^id, status: :idle} = Tracer.active()

    assert {:ok, %{entries: [%{seq: 0, kind: :configured}], truncated?: false}} =
             Tracer.entries(id, since: 0, order: :asc)
  end

  test "resumes a stopped session" do
    assert {:ok, %{id: id}} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, %{id: ^id},
                    [%{kind: :stopped, origin: nil, reason: :event_limit}]}

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{id: ^id, traces: 2}, [%{kind: :stopped, traces: 1}]}

    assert {:ok, %{entries: entries}} = Tracer.entries(id)

    assert Enum.map(entries, &{&1.seq, &1.kind}) == [
             {6, :stopped},
             {5, :trace},
             {4, :started},
             {3, :stopped},
             {2, :trace},
             {1, :started},
             {0, :configured}
           ]
  end

  test "tracks the run a resumed session is on" do
    assert {:ok, %{run_started_at: nil, run_traces_before: 0}} = configure(%{max_events: 1})
    assert {:ok, %{run_started_at: first, run_traces_before: 0} = run} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}

    assert {:ok, %{started_at: started_at, run_started_at: second, run_traces_before: 1}} =
             Tracer.start(:ui)

    assert started_at == run.started_at
    assert DateTime.compare(second, first) == :gt
  end

  test "derives a saved session's run from its log" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure(%{max_events: 1})

    for _run <- 1..2 do
      assert {:ok, _session} = Tracer.start(:ui)
      Date.leap_year?(~D[2024-01-01])
      assert_receive {:session_entries, _session, [%{kind: :stopped}]}
    end

    assert {:ok, %{entries: entries}} = Tracer.entries(id)
    started = Enum.find(entries, &(&1.kind == :started))
    started_at = DateTime.from_unix!(started.at, :microsecond)
    assert {:ok, _session} = Tracer.create(:ui)

    assert {:ok, %{run_started_at: ^started_at, run_traces_before: 1}, :saved} =
             Tracer.session(id)

    assert {:ok, %{run_started_at: ^started_at, run_traces_before: 1}} = Tracer.load(id)
  end

  test "reads the active session from memory", %{session: %{id: id}} do
    assert {:ok, %{id: ^id, save: false}, :active} = Tracer.session(id)

    assert {:ok, %{id: saved}} = Tracer.create(:ui, save: true)
    assert {:ok, %{id: ^saved}, :active} = Tracer.session(saved)
  end

  test "reads a saved session that is not active from its row" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, %{config: config, node: node}} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{storage_limit: storage_limit}, [%{kind: :stopped}]}
    assert {:ok, _session} = Tracer.create(:ui)

    assert {:ok,
            %{
              id: ^id,
              save: true,
              status: :stopped,
              stop_reason: :event_limit,
              traces: 1,
              seq: 4,
              node: ^node,
              config: ^config,
              storage_limit: ^storage_limit
            }, :saved} = Tracer.session(id)
  end

  test "does not find a missing or closed unsaved session", %{session: %{id: id}} do
    assert {:error, :not_found} = Tracer.session(0)
    assert :ok = Tracer.close()
    assert {:error, :not_found} = Tracer.session(id)
  end

  test "reads the storage limit from its setting" do
    Repo.delete_all(Voyager.Schemas.Setting)
    assert Tracer.storage_limit_mb() == 100
    {:ok, _} = Voyager.Settings.put(:trace_storage_limit_mb, 7)
    assert Tracer.storage_limit_mb() == 7
  end

  for save <- [true, false] do
    describe "search/3 with save: #{save}" do
      @describetag save: save

      test "takes %, _ and backslash literally", %{save: save} do
        {id, [percent, _digit, underscore, _letter, backslash]} =
          searchable(save, ["100%", "1000", "a_b", "axb", "c:\\d"])

        assert {:ok, %{entries: [^percent], total: 1}} = Tracer.search(id, "100%")
        assert {:ok, %{entries: [^underscore], total: 1}} = Tracer.search(id, "a_b")
        assert {:ok, %{entries: [^backslash], total: 1}} = Tracer.search(id, "\\")
      end

      test "folds ASCII case only", %{save: save} do
        {id, [ascii, polish]} = searchable(save, ["HeLLo", "ŻÓŁW"])

        assert {:ok, %{entries: [^ascii], total: 1}} = Tracer.search(id, "hello")
        assert {:ok, %{entries: [], total: 0}} = Tracer.search(id, "żółw")
        assert {:ok, %{entries: [^polish], total: 1}} = Tracer.search(id, "ŻÓŁw")
      end

      test "pages newest first, over trace rows only, counting on the first page", %{save: save} do
        {id, [a, b, c, _other]} = searchable(save, ["needle a", "needle b", "needle c", "other"])
        assert :ok = Tracer.stop(:ui)
        assert_receive {:session_entries, _session, [%{kind: :stopped}]}

        assert {:ok, %{entries: [^c, ^b], total: 3}} = Tracer.search(id, "needle", limit: 2)

        assert {:ok, %{entries: [^a], total: nil}} =
                 Tracer.search(id, "needle", before: b.seq, limit: 2)

        assert {:ok, %{entries: [], total: nil}} = Tracer.search(id, "needle", before: a.seq)
        assert {:ok, %{total: 4}} = Tracer.search(id, "")
      end

      test "finds a pid shown under any node index", %{save: save} do
        "<0." <> rest = Voyager.Pid.format(self(), :distribution)
        {id, [entry]} = searchable(save, ["pid"])

        assert {:ok, %{entries: [^entry]}} = Tracer.search(id, "<0." <> rest)
        assert {:ok, %{entries: [^entry]}} = Tracer.search(id, "<7." <> rest)
        assert {:ok, %{entries: [^entry]}} = Tracer.search(id, "#PID<12." <> rest)
        assert {:ok, %{entries: []}} = Tracer.search(id, "<7.0.0>")
      end
    end
  end

  test "searches every trace an unsaved session keeps, whatever controls follow them" do
    kept = Tracer.kept_traces()
    {id, [oldest | _]} = searchable(false, Enum.map(1..kept, &"trace #{&1}"))
    assert :ok = Tracer.stop(:ui)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}

    assert {:ok, %{entries: [^oldest], total: 1}} = Tracer.search(id, ~s("trace 1"))
    assert {:ok, %{total: ^kept}} = Tracer.search(id, "")
  end

  test "searches a saved session that is not active" do
    {id, [entry]} = searchable(true, ["needle"])
    assert :ok = Tracer.stop(:ui)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}
    assert {:ok, _session} = Tracer.create(:ui)

    assert {:ok, %{entries: [^entry], total: 1}} = Tracer.search(id, "needle")
  end

  test "does not search a missing or closed session", %{session: %{id: id}} do
    assert {:error, :not_found} = Tracer.search(1_000_000, "x")
    assert :ok = Tracer.close()
    assert {:error, :not_found} = Tracer.search(id, "x")
  end

  test "rejects invalid search options" do
    assert_raise ArgumentError, ~r/invalid :limit option/, fn ->
      Tracer.search(1, "x", limit: 0)
    end

    assert_raise ArgumentError, ~r/invalid :before option/, fn ->
      Tracer.search(1, "x", before: -1)
    end

    assert_raise ArgumentError, fn -> Tracer.search(1, "x", order: :asc) end
  end

  test "rejects invalid entries options" do
    assert_raise ArgumentError, ~r/invalid :limit option/, fn ->
      Tracer.entries(1, limit: 0)
    end

    assert_raise ArgumentError, ~r/invalid :since option/, fn ->
      Tracer.entries(1, since: -1)
    end

    assert_raise ArgumentError, ~r/invalid :before option/, fn ->
      Tracer.entries(1, before: "9")
    end

    assert_raise ArgumentError, ~r/invalid :order option/, fn -> Tracer.entries(1, order: :up) end
    assert_raise ArgumentError, fn -> Tracer.entries(1, sort: :asc) end
  end

  test "summarizes a session the same from memory and from the database" do
    summaries =
      for save <- [false, true] do
        assert {:ok, %{id: id}} = Tracer.create(:ui, save: save)
        assert {:ok, _session} = configure(%{return_trace: true, max_events: 2})
        # Renamed between runs, as the agent caches a name per run; the latest sorts first.
        run_named(id, :z_name, ~D[2024-01-01])
        run_named(id, :a_name, ~D[2023-01-01])

        assert {:ok, summary} = Tracer.summary(id)
        %{summary | slowest: Enum.map(summary.slowest, &Map.take(&1, [:type, :mfa, :pid]))}
      end

    assert [unsaved, saved] = summaries
    assert unsaved == saved

    assert %{calls: 2, returns: 2, exceptions: 0, functions: %{{Date, :leap_year?, 1} => 2}} =
             saved

    assert %{slowest: [_, _]} = saved
    assert [{pid, {:a_name, 2}}] = Map.to_list(saved.processes)
    assert pid == self()
    assert {:error, :not_found} = Tracer.summary(-1)
  end

  test "overview/1 returns runs, activity slices and summary for unsaved and saved sessions" do
    for save <- [false, true] do
      assert {:ok, %{id: id}} = Tracer.create(:ui, save: save)
      assert {:ok, _session} = configure(%{return_trace: true, max_events: 2})
      run_named(id, :z_name, ~D[2024-01-01])
      run_named(id, :a_name, ~D[2023-01-01])

      assert {:ok, %{runs: [run1, run2], activity: activity, summary: summary}} =
               Tracer.overview(id)

      assert run1.traces == 2
      assert run2.traces == 2
      assert %{live?: false, segments: [_first, %{gap_before_ms: gap}] = segments} = activity
      assert is_integer(gap)
      assert segments |> Enum.flat_map(& &1.counts) |> Enum.sum() == 4
      assert summary.calls == 2
      assert summary.returns == 2
    end

    assert {:error, :not_found} = Tracer.overview(-999)
  end

  defp run_named(id, name, date) do
    Process.register(self(), name)
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(date)
    assert_receive {:session_entries, %{id: ^id}, [%{kind: :stopped}]}
    Process.unregister(name)
  end

  test "puts the call's duration on its return" do
    assert {:ok, %{id: id}} = configure(%{return_trace: true, max_events: 4})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    Date.leap_year?(~D[2023-01-01])
    assert_receive {:session_entries, %{id: ^id}, [%{kind: :stopped}]}

    assert [call1, ret1, call2, ret2] = traces(id)
    assert %{type: :return, value: false, duration_us: duration} = ret2
    assert duration == ret2.at - call2.at
    assert %{type: :return, value: true, duration_us: _} = ret1
    refute Map.has_key?(call1, :duration_us)
  end

  test "a restarted Tracer interrupts the run after the Writer's buffered rows land" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    old = Process.whereis(Tracer)
    Process.exit(old, :kill)

    Stream.repeatedly(fn -> Process.whereis(Tracer) end)
    |> Enum.find(&(&1 && &1 != old))

    _ = :sys.get_state(Tracer)
    assert %{status: :stopped, stop_reason: :interrupted} = TraceSessionQueries.get(id)
  end

  test "a restarted Tracer tells the indicator the session is gone" do
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
    Process.exit(Process.whereis(Tracer), :kill)

    assert_receive {:session_updated, nil}
  end

  test "the writer saves what it buffered when it shuts down" do
    assert {:ok, session} = Tracer.create(:ui, save: true)

    entry = %{
      seq: 0,
      kind: :trace,
      at: 1,
      type: :call,
      pid: self(),
      process: nil,
      mfa: {Date, :leap_year?, 1}
    }

    Writer.append(session, [entry])
    old = Process.whereis(Writer)
    GenServer.stop(old)
    assert Repo.aggregate(TraceEvent, :count) == 1

    Stream.repeatedly(fn -> {Process.whereis(Writer), Process.whereis(Tracer)} end)
    |> Enum.find(fn {writer, tracer} -> writer && writer != old && tracer end)

    _ = :sys.get_state(Tracer)
  end

  test "returns the config errors" do
    assert {:error, %Ecto.Changeset{valid?: false}} = configure(%{module: nil})
    refute_receive {:session_entries, _session, _entries}
  end

  test "resolves selected pids on the traced node" do
    attrs = %{module: "Elixir.Date", pids: ["<0.45.6>"], max_events: 1}
    assert {:error, :noconnection} = Tracer.configure(:other@nohost, attrs, :ui)
    refute_receive {:session_entries, _session, _entries}
  end

  test "resolves the pids again on start" do
    assert {:ok, _session} = configure()
    :sys.replace_state(Tracer, &put_in(&1.session.node, :other@nohost))
    assert {:error, :noconnection} = Tracer.start(:ui)
  end

  test "refuses to start a session reconfigured while its pids resolve" do
    assert {:ok, _session} = configure()

    :sys.suspend(Tracer)
    start = Task.async(fn -> Tracer.start(:ui) end)
    await_queued(1)
    reconfigure = Task.async(fn -> configure(%{max_events: 5}) end)
    await_queued(2)
    :sys.resume(Tracer)

    assert {:error, :changed} = Task.await(start)
    assert {:ok, %{status: :idle}} = Task.await(reconfigure)
  end

  test "refuses to start without a config" do
    assert {:error, :not_configured} = Tracer.start(:ui)
  end

  test "refuses to change the session while running" do
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert {:error, :busy} = Tracer.start(:ui)
    assert {:error, :busy} = configure()
    assert {:error, :busy} = Tracer.create(:ui)
    assert {:error, :busy} = Tracer.close()
  end

  test "ends a disconnected session when its tracer goes down" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    assert :ok = Tracer.disconnecting()
    _ = :sys.get_state(Tracer)
    Process.exit(tracer, :noconnection)

    assert_receive {:session_entries, %{stop_reason: :disconnected},
                    [%{kind: :stopped, origin: nil, reason: :disconnected}]}
  end

  test "ends the session when the remote tracer dies" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    Process.exit(tracer, :kill)

    assert_receive {:session_entries, _session,
                    [%{kind: :stopped, reason: {:tracer_down, :killed}}]}
  end

  test "keeps every control entry but only the newest events", %{session: session} do
    assert {:ok, _session} = configure(%{max_events: 501})
    assert {:ok, _session} = Tracer.start(:ui)

    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, %{traces: 501}, [%{kind: :stopped}]}

    assert {:ok, %{entries: [%{kind: :stopped} | entries], truncated?: true}} =
             Tracer.entries(session.id, limit: 1_000)

    assert [%{kind: :started}, %{kind: :configured}] = Enum.take(entries, -2)
    assert length(entries) == 502
  end

  test "logs the drops reported when the run ends" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    send(Tracer, {:voyager_trace_done, tracer, :time_limit, %{traces: 0, dropped: 3}})

    assert_receive {:session_entries, %{dropped: 3},
                    [
                      %{kind: :dropped, count: 3},
                      %{kind: :stopped, reason: :time_limit, dropped: 3}
                    ]}

    Process.exit(tracer, :kill)
  end

  test "logs batches dropped here and by the agent" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)

    :sys.suspend(Tracer)
    for _ <- 1..1_005, do: send(Tracer, {:voyager_trace_events, tracer, [%{}], 0})
    :sys.resume(Tracer)

    assert_receive {:session_entries, %{traces: 1, dropped: 4},
                    [%{seq: 2, kind: :dropped, count: 4}, %{seq: 3, kind: :trace}]}

    assert_receive {:session_entries, %{traces: 1_001, dropped: 4}, [%{seq: 1_003, kind: :trace}]}

    send(Tracer, {:voyager_trace_events, tracer, [%{}], 2})

    assert_receive {:session_entries, %{dropped: 6},
                    [%{seq: 1_004, kind: :dropped, count: 2}, %{seq: 1_005, kind: :trace}]}
  end

  test "an unsaved session ignores the Writer's backlog" do
    on_exit(fn -> :sys.resume(Writer) end)
    assert {:ok, saved} = Tracer.create(:ui, save: true)
    :sys.suspend(Writer)

    entry = %{
      seq: 0,
      kind: :trace,
      at: 1,
      type: :call,
      pid: self(),
      process: nil,
      mfa: {Date, :leap_year?, 1}
    }

    Writer.append(saved, for(seq <- 0..10_000, do: %{entry | seq: seq}))
    assert Writer.overloaded?()

    assert {:ok, _session} = Tracer.create(:ui)
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    send(Tracer, {:voyager_trace_events, tracer, [entry], 0})
    _ = :sys.get_state(Tracer)

    assert %{traces: 1, dropped: 0} = Tracer.active()
    :sys.resume(Writer)
  end

  test "keeps a saved session's bytes in step with its saved rows" do
    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure(%{max_events: 3})
    assert {:ok, _session} = Tracer.start(:ui)
    for _ <- 1..3, do: Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}

    Writer.flush()
    _ = :sys.get_state(Tracer)
    assert %{bytes: bytes} = TraceSessionQueries.get(id)
    assert bytes > 0
    assert %{bytes: ^bytes} = Tracer.active()
  end

  test "the writer saves a full queue without waiting for its timer" do
    assert {:ok, session} = Tracer.create(:ui, save: true)

    entries =
      for seq <- 0..1_999 do
        %{
          seq: seq,
          kind: :trace,
          at: 1,
          type: :call,
          pid: self(),
          process: nil,
          mfa: {Date, :leap_year?, 1}
        }
      end

    Writer.append(session, entries)
    _ = :sys.get_state(Writer)
    assert Repo.aggregate(TraceEvent, :count) == 2_000
  end

  test "sheds batches while the writer lags" do
    assert {:ok, _session} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)

    on_exit(fn -> :sys.resume(Writer) end)
    :sys.suspend(Writer)
    event = %{type: :call, pid: self(), process: nil, mfa: {Date, :leap_year?, 1}, at: 1}
    batch = List.duplicate(event, 200)
    for _ <- 1..60, do: send(Tracer, {:voyager_trace_events, tracer, batch, 0})
    _ = :sys.get_state(Tracer)
    assert %{dropped: dropped} = Tracer.active()
    assert dropped > 0
    :sys.resume(Writer)
  end

  test "ends a saved run whose entries cannot be saved" do
    tracer_pid = Process.whereis(Tracer)
    assert {:ok, _session} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    Writer.flush()
    assert {:ok, _session} = Tracer.start(:ui)
    Repo.delete_all(TraceSession)

    capture_log(fn ->
      assert_receive {:session_entries, _session, [%{kind: :stopped, reason: :write_failed}]},
                     1_000

      Writer.flush()
    end)

    assert Process.whereis(Tracer) == tracer_pid
  end

  test "returns the agent's refusal on start" do
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, :unknown_function} = Tracer.start(:ui)
    refute_receive {:session_entries, %{status: :running}, _entries}
  end

  test "creates and starts a session at once", %{session: %{id: old_id}} do
    attrs = %{module: "Elixir.Date", processes: "all", max_events: 1_000}

    assert {:ok, %{id: id, origin: :mcp, status: :running}} =
             Tracer.create_and_start(Node.self(), attrs, :mcp)

    refute id == old_id
    assert_receive {:session_activated, %{id: ^id, status: :idle}}
    assert_receive {:session_entries, %{id: ^id}, [%{seq: 0, kind: :configured, origin: :mcp}]}
    assert_receive {:session_entries, %{id: ^id}, [%{seq: 1, kind: :started, origin: :mcp}]}
    assert {:error, :busy} = Tracer.create_and_start(Node.self(), attrs, :mcp)
  end

  test "keeps the previous session when creating and starting one fails", %{session: %{id: id}} do
    attrs = %{module: "Elixir.Voyager.NoSuchModule", processes: "all", max_events: 1_000}
    assert {:error, :unknown_function} = Tracer.create_and_start(Node.self(), attrs, :mcp)

    attrs = %{module: "Elixir.Date", pids: ["<0.45.6>"], max_events: 1}
    assert {:error, :noconnection} = Tracer.create_and_start(:other@nohost, attrs, :mcp)

    assert {:error, %Ecto.Changeset{}} = Tracer.create_and_start(Node.self(), %{}, :mcp)
    assert %{id: ^id} = Tracer.active()
  end

  test "emits telemetry without the traced function" do
    events = [
      [:voyager, :trace, :start],
      [:voyager, :trace, :start_failed],
      [:voyager, :trace, :stop]
    ]

    handler = {__MODULE__, self()}
    :telemetry.attach_many(handler, events, &__MODULE__.forward_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert :ok = Tracer.stop(:mcp)
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, _reason} = Tracer.start(:mcp)

    assert_receive {:telemetry, [:voyager, :trace, :start], _,
                    %{origin: :ui, processes: :pids, capture: :args} = meta}

    refute Map.has_key?(meta, :module)

    assert_receive {:telemetry, [:voyager, :trace, :stop],
                    %{events: 0, dropped: 0, duration_ms: _}, %{origin: :ui, reason: :stopped}}

    assert_receive {:telemetry, [:voyager, :trace, :start_failed], _, %{origin: :mcp}}
  end

  defp searchable(save, args) do
    {:ok, %{id: id}} = Tracer.create(:ui, save: save)
    {:ok, _session} = configure()
    {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    event = %{type: :call, pid: self(), process: nil, mfa: {Date, :leap_year?, 1}, at: 10}
    send(Tracer, {:voyager_trace_events, tracer, Enum.map(args, &Map.put(event, :args, [&1])), 0})
    _ = :sys.get_state(Tracer)
    Writer.flush()
    {id, traces(id)}
  end

  defp traces(id) do
    {:ok, %{entries: entries}} = Tracer.entries(id, since: 0, order: :asc)
    Enum.filter(entries, &(&1.kind == :trace))
  end

  defp await_queued(len) do
    Stream.repeatedly(fn -> Process.info(Process.whereis(Tracer), :message_queue_len) end)
    |> Enum.find(&(&1 == {:message_queue_len, len}))
  end

  def forward_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp configure(overrides \\ %{}, origin \\ :ui) do
    attrs =
      Map.merge(
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          pids: [Voyager.Pid.format(self(), :distribution)],
          capture: :args,
          max_events: 1_000,
          max_time_ms: 5_000,
          budget: 50
        },
        overrides
      )

    Tracer.configure(Node.self(), attrs, origin)
  end
end
