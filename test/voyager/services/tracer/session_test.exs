defmodule Voyager.Services.Tracer.SessionTest do
  use ExUnit.Case, async: true

  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session

  defp session(fields \\ []) do
    struct!(%Session{id: 1, origin: :ui, created_at: ~U[2026-01-01 00:00:00Z]}, fields)
  end

  describe "running/3" do
    test "marks the session running with its tracer and limit" do
      tracer = self()
      running = Session.running(session(), tracer, 1_000)

      assert %Session{tracer: ^tracer, status: :running, storage_limit: 1_000} = running
      assert %DateTime{} = running.started_at
      assert running.stop_reason == nil
      assert running.stopped_at == nil
    end

    test "keeps the first run's start and clears the last run's end" do
      started_at = ~U[2026-01-01 01:00:00Z]

      stopped =
        session(
          status: :stopped,
          started_at: started_at,
          stopped_at: ~U[2026-01-01 02:00:00Z],
          stop_reason: :stopped
        )

      running = Session.running(stopped, self(), 0)

      assert running.started_at == started_at
      assert running.stopped_at == nil
      assert running.stop_reason == nil
    end
  end

  describe "stopped/3" do
    test "records the reason, the dropped total and the stop time" do
      running = session(status: :running, tracer: self(), dropped: 1)
      stopped = Session.stopped(running, :event_limit, 9)

      assert %Session{status: :stopped, stop_reason: :event_limit, dropped: 9} = stopped
      assert %DateTime{} = stopped.stopped_at
      assert stopped.tracer == running.tracer
    end
  end

  describe "from_row/4" do
    @row %TraceSession{
      id: 7,
      origin: :mcp,
      status: :stopped,
      stop_reason: :time_limit,
      traces: 12,
      dropped: 3,
      bytes: 456,
      started_at: ~U[2026-01-02 03:00:00Z],
      stopped_at: ~U[2026-01-02 04:00:00Z],
      inserted_at: ~N[2026-01-02 02:00:00]
    }

    test "builds a saved session from the row and its control entries" do
      config = %Config{module: "Elixir.Date"}

      session =
        Session.from_row(@row, [%{kind: :configured, node: :a@host, config: config}], 20, 5_000)

      assert %Session{
               id: 7,
               origin: :mcp,
               save: true,
               node: :a@host,
               config: ^config,
               status: :stopped,
               stop_reason: :time_limit,
               traces: 12,
               dropped: 3,
               bytes: 456,
               storage_limit: 5_000,
               seq: 20,
               created_at: ~U[2026-01-02 02:00:00Z],
               started_at: ~U[2026-01-02 03:00:00Z],
               stopped_at: ~U[2026-01-02 04:00:00Z]
             } = session
    end
  end
end
