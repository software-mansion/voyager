defmodule Voyager.Services.TracerTest do
  # async: false because these tests swap the global erpc impl and share the app's Tracer.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer
  alias Voyager.Test.VoyagerAgentFixture

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    on_exit(fn -> Tracer.stop() end)
    :ok
  end

  test "broadcasts the configured session, its events and the stop" do
    assert {:ok, %{id: id, origin: :ui, status: :configured}} = configure()
    assert_receive {:tracing_configured, %{id: ^id}}

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start()
    assert_receive {:tracing_started, %{id: ^id}}

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:trace_events, %{id: ^id, events: 1},
                    [%{id: 0, type: :call, mfa: {Date, :leap_year?, 1}}]},
                   1_000

    assert :ok = Tracer.stop()

    assert_receive {:tracing_ended,
                    %{id: ^id, status: :stopped, stop_reason: :stopped, ended_at: %DateTime{}}}

    assert {%{id: ^id, status: :stopped}, [%{id: 0}]} = Tracer.current()
  end

  test "resumes a stopped session" do
    assert {:ok, %{id: id}} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start()
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:tracing_ended, %{id: ^id, stop_reason: :event_limit}}

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start()
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:tracing_ended, %{id: ^id, events: 2}}
    assert {_session, [%{id: 1}, %{id: 0}]} = Tracer.current()
  end

  test "returns the config errors" do
    assert {:error, %Ecto.Changeset{valid?: false}} = configure(%{module: nil})
    refute_receive {:tracing_configured, _session}
  end

  test "resolves selected pids on the traced node" do
    attrs = %{module: "Elixir.Date", pids: ["<0.45.6>"], max_events: 1}
    assert {:error, :noconnection} = Tracer.configure(:other@nohost, attrs, :ui)
    refute_receive {:tracing_configured, _session}
  end

  test "refuses to start without a config" do
    :sys.replace_state(Tracer, &%{&1 | session: nil})
    assert {:error, :not_configured} = Tracer.start()
  end

  test "refuses to configure or start while running" do
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start()
    assert {:error, :busy} = Tracer.start()
    assert {:error, :busy} = configure()
  end

  test "ends a disconnected session when its tracer goes down" do
    assert {:ok, %{id: id}} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start()
    assert :ok = Tracer.disconnected()
    _ = :sys.get_state(Tracer)
    Process.exit(tracer, :noconnection)
    assert_receive {:tracing_ended, %{id: ^id, stop_reason: :disconnected}}
  end

  test "ends the session when the remote tracer dies" do
    assert {:ok, %{id: id}} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start()
    Process.exit(tracer, :kill)
    assert_receive {:tracing_ended, %{id: ^id, stop_reason: {:tracer_down, :killed}}}
  end

  test "keeps only the newest events" do
    assert {:ok, %{id: id}} = configure(%{max_events: 501})
    assert {:ok, _session} = Tracer.start()

    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])

    assert_receive {:tracing_ended, %{id: ^id, events: 501}}
    assert {_session, [%{id: 500} | _] = events} = Tracer.current()
    assert length(events) == 500
  end

  test "drops batches while its mailbox is over the limit" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start()

    :sys.suspend(Tracer)
    for _ <- 1..1_005, do: send(Tracer, {:voyager_trace_events, tracer, [%{}], 0})
    :sys.resume(Tracer)

    assert_receive {:trace_events, %{events: 1_001, dropped: 4}, [%{id: 1_000}]}
  end

  test "returns the agent's refusal on start" do
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, :unknown_function} = Tracer.start()
    refute_receive {:tracing_started, _session}
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
    assert {:ok, _session} = Tracer.start()
    assert :ok = Tracer.stop()
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"}, :mcp)
    assert {:error, _reason} = Tracer.start()

    assert_receive {:telemetry, [:voyager, :trace, :start], _,
                    %{origin: :ui, processes: :pids, capture: :args} = meta}

    refute Map.has_key?(meta, :module)

    assert_receive {:telemetry, [:voyager, :trace, :stop],
                    %{events: 0, dropped: 0, duration_ms: _}, %{origin: :ui, reason: :stopped}}

    assert_receive {:telemetry, [:voyager, :trace, :start_failed], _, %{origin: :mcp}}
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
