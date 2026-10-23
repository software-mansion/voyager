defmodule Voyager.Services.TracerTest do
  # async: false because these tests swap the global erpc impl and share the app's Tracer.
  use Voyager.DataCase, async: false

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Test.Recursive
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
    end)

    {:ok, session} = Tracer.create(:ui)
    %{session: session}
  end

  test "creates and closes the active session", %{session: %{id: id}} do
    assert_receive {:session_created, %{id: ^id, origin: :ui, save: false, status: :idle}}

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
    assert {:ok, %{entries: [%{seq: 1}, %{seq: 2}]}} = Tracer.entries(id, since: 1, limit: 2)
    assert {:ok, %{entries: [], truncated?: false}} = Tracer.entries(id, since: 4)
  end

  test "saves a saved session's log as it is appended" do
    assert {:ok, %{id: id}} = Tracer.create(:mcp, save: true)
    assert id > 0
    assert %{status: :idle, origin: :mcp} = TraceSessionQueries.get(id)

    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert %{status: :running, started_at: %DateTime{}} = TraceSessionQueries.get(id)

    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: 1}, [%{kind: :trace}]}, 1_000
    assert :ok = Tracer.stop(:mcp)
    assert_receive {:session_entries, _session, [%{kind: :stopped}]}

    assert %{status: :stopped, stop_reason: "stopped", traces: 1, bytes: bytes, node: node} =
             TraceSessionQueries.get(id)

    assert bytes > 0
    assert node == Atom.to_string(Node.self())

    assert {:ok, %{entries: entries, truncated?: false}} = Tracer.entries(id)

    assert [
             %{seq: 3, kind: :stopped, origin: :mcp, reason: "stopped", traces: 1},
             %{seq: 2, kind: :trace, mfa: "Date.leap_year?/1", args: "[~D[2024-01-01]]"},
             %{seq: 1, kind: :started, origin: :ui},
             %{seq: 0, kind: :configured, node: node_atom, config: %Config{module: "Elixir.Date"}}
           ] = entries

    assert node_atom == Node.self()
    assert {:ok, %{entries: [%{seq: 1}, %{seq: 2}]}} = Tracer.entries(id, since: 1, limit: 2)
    assert {:ok, %{entries: [%{seq: 1}]}} = Tracer.entries(id, before: 2, limit: 1)
  end

  test "stops a saved session over the storage limit" do
    Application.put_env(:voyager, :trace_storage_limit_mb, 0)
    on_exit(fn -> Application.delete_env(:voyager, :trace_storage_limit_mb) end)

    assert {:ok, %{id: id}} = Tracer.create(:ui, save: true)
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, %{stop_reason: :storage_limit},
                    [%{kind: :stopped, origin: nil, reason: :storage_limit}]},
                   1_000

    assert %{stop_reason: "storage_limit"} = TraceSessionQueries.get(id)
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

    assert_receive {:session_created, %{id: ^id}}
    assert node == Node.self()
    assert %Config{module: "Elixir.Date", max_events: 1} = config
    assert %{id: ^id} = Tracer.active()

    assert {:ok, %{status: :running}} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: 2}, [%{seq: 6, kind: :stopped}]}
    assert %{traces: 2} = TraceSessionQueries.get(id)
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

  test "resumes a stopped session" do
    assert {:ok, %{id: id}} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_entries, %{id: ^id},
                    [%{kind: :stopped, origin: nil, reason: :event_limit}]}

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{id: ^id, traces: 2}, [%{kind: :stopped}]}

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

  test "a recursive call's inner duration is shorter than its outer one" do
    Code.ensure_loaded!(Recursive)

    assert {:ok, %{id: id}} =
             configure(%{
               module: "Elixir.Voyager.Test.Recursive",
               function: "countdown",
               return_trace: true,
               max_events: 4
             })

    assert {:ok, _session} = Tracer.start(:ui)
    Recursive.countdown(1)
    assert_receive {:session_entries, %{id: ^id}, [%{kind: :stopped}]}

    assert [outer_call, inner_call, inner_ret, outer_ret] = traces(id)
    assert %{type: :call, args: [1]} = outer_call
    assert %{type: :call, args: [0]} = inner_call
    assert inner_ret.duration_us < outer_ret.duration_us
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

    assert {:ok, %{entries: [%{seq: 503} | _], truncated?: false}} = Tracer.entries(session.id)

    assert {:ok, %{entries: [%{seq: 3}, %{seq: 1}, %{seq: 0}], truncated?: true}} =
             Tracer.entries(session.id, before: 4, limit: 3)

    assert {:ok, %{entries: [%{seq: 0}, %{seq: 1}, %{seq: 3}], truncated?: true}} =
             Tracer.entries(session.id, since: 0, limit: 3)

    assert {:ok, %{entries: [%{seq: 3}], truncated?: false}} =
             Tracer.entries(session.id, since: 3, limit: 1)
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

    assert_receive {:session_entries, %{traces: 0, dropped: 1},
                    [%{seq: 2, kind: :dropped, count: 1}]}

    assert_receive {:session_entries, %{traces: 0, dropped: 4},
                    [%{seq: 5, kind: :dropped, count: 1}]}

    assert_receive {:session_entries, %{traces: 1_001, dropped: 4}, [%{seq: 1_006, kind: :trace}]}

    send(Tracer, {:voyager_trace_events, tracer, [%{}], 2})

    assert_receive {:session_entries, %{dropped: 6},
                    [%{seq: 1_007, kind: :dropped, count: 2}, %{seq: 1_008, kind: :trace}]}
  end

  test "returns the agent's refusal on start" do
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, :unknown_function} = Tracer.start(:ui)
    refute_receive {:session_entries, %{status: :running}, _entries}
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

  defp traces(id) do
    {:ok, %{entries: entries}} = Tracer.entries(id, since: 0)
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
