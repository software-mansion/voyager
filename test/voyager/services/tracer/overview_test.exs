defmodule Voyager.Services.Tracer.OverviewTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Overview
  alias Voyager.Services.Tracer.Session

  @first %Config{module: "Elixir.Date", function: "leap_year?", arity: 1, max_events: 100}
  @second %{@first | capture: :args}

  test "pairs controls into runs, each with its config and its own traces and drops" do
    controls = [
      %{seq: 5, kind: :started, at: 30_000_000, origin: :mcp},
      %{seq: 4, kind: :configured, at: 25_000_000, origin: :ui, node: :a@host, config: @second},
      %{
        seq: 3,
        kind: :stopped,
        at: 15_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 80,
        dropped: 2
      },
      %{seq: 1, kind: :started, at: 5_000_000, origin: :ui},
      %{seq: 0, kind: :configured, at: 1_000_000, origin: :ui, node: :a@host, config: @first}
    ]

    session = %Session{
      id: 1,
      origin: :ui,
      created_at: ~U[2026-01-01 00:00:00Z],
      config: @second,
      status: :running,
      traces: 100,
      run_traces_before: 80,
      dropped: 5
    }

    assert [first, second] = Overview.runs(controls, session, DateTime.from_unix!(40, :second))

    assert %{index: 1, reason: :stopped, duration_ms: 10_000, traces: 80, dropped: 2} = first
    assert %{config: @first, previous_config: nil} = first

    assert %{index: 2, reason: :running, duration_ms: 10_000, traces: 20, dropped: 3} = second
    assert %{origin: :mcp, config: @second, previous_config: @first} = second
  end
end
