defmodule Voyager.Services.Tracer.OverviewTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Overview
  alias Voyager.Services.Tracer.Session

  @first %Config{module: "Elixir.Date", function: "leap_year?", arity: 1, max_events: 100}
  @second %{@first | scope: :local, max_events: 500}

  defp session(overrides) do
    struct!(
      %Session{
        id: 1,
        origin: :ui,
        created_at: ~U[2026-01-01 00:00:00Z],
        config: @first
      },
      overrides
    )
  end

  test "runs/3 pairs multi-run controls with durations and inter-run config changes" do
    controls = [
      %{
        seq: 7,
        kind: :stopped,
        at: 50_000_000,
        origin: :mcp,
        reason: :event_limit,
        traces: 500,
        dropped: 2
      },
      %{seq: 5, kind: :started, at: 30_000_000, origin: :mcp},
      %{seq: 4, kind: :configured, at: 25_000_000, origin: :ui, node: :a@host, config: @second},
      %{
        seq: 3,
        kind: :stopped,
        at: 15_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 80,
        dropped: 0
      },
      %{seq: 1, kind: :started, at: 5_000_000, origin: :ui},
      %{seq: 0, kind: :configured, at: 1_000_000, origin: :ui, node: :a@host, config: @first}
    ]

    shown = session(status: :stopped, stop_reason: :event_limit, config: @second)
    [run1, run2] = Overview.runs(controls, shown)

    assert run1.index == 1
    assert run1.duration_ms == 10_000
    assert run1.traces == 80
    assert run1.reason == :stopped
    assert run1.origin == :ui
    assert run1.config == @first
    assert run1.previous_config == nil

    assert run2.index == 2
    assert run2.duration_ms == 20_000
    assert run2.traces == 500
    assert run2.dropped == 2
    assert run2.reason == :event_limit
    assert run2.origin == :mcp
    assert run2.config == @second
    assert run2.previous_config == @first
  end

  test "runs/3 handles a running run and a boot-interrupted run without a stopped entry" do
    controls = [
      %{seq: 1, kind: :started, at: 10_000_000, origin: :ui},
      %{seq: 0, kind: :configured, at: 1_000_000, origin: :ui, node: :a@host, config: @first}
    ]

    now = DateTime.from_unix!(22_000_000, :microsecond)

    [running] =
      Overview.runs(
        controls,
        session(status: :running, traces: 45, run_traces_before: 10, dropped: 3),
        now
      )

    assert running.reason == :running
    assert running.traces == 35
    assert running.dropped == 3
    assert running.duration_ms == 12_000
    assert running.stopped_at == nil

    stopped_at = DateTime.from_unix!(18_000_000, :microsecond)

    [interrupted] =
      Overview.runs(
        controls,
        session(
          status: :stopped,
          stop_reason: :interrupted,
          stopped_at: stopped_at,
          traces: 45,
          run_traces_before: 10
        ),
        now
      )

    assert interrupted.reason == :interrupted
    assert interrupted.traces == 35
    assert interrupted.duration_ms == 8_000
    assert interrupted.stopped_at == stopped_at
  end

  test "activity/3 slices each run into fixed-width buckets with the gap between runs" do
    controls = [
      %{
        seq: 6,
        kind: :stopped,
        at: 30_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 2,
        dropped: 0
      },
      %{seq: 3, kind: :started, at: 10_000_000, origin: :ui},
      %{
        seq: 2,
        kind: :stopped,
        at: 6_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 1,
        dropped: 0
      },
      %{seq: 0, kind: :started, at: 1_000_000, origin: :ui}
    ]

    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    entries = [
      %{seq: 1, kind: :trace, at: 2_000_000},
      %{seq: 4, kind: :trace, at: 12_000_000},
      %{seq: 5, kind: :trace, at: 28_000_000}
    ]

    timestamps = Overview.trace_timestamps(runs, entries)

    assert %{bucket_ms: 1_000, live?: false, end_us: 30_000_000, segments: [first, second]} =
             Overview.activity(runs, timestamps)

    assert first == %{start_us: 1_000_000, counts: [0, 1, 0, 0, 0], gap_before_ms: nil}
    assert second.start_us == 10_000_000
    assert second.gap_before_ms == 4_000
    assert length(second.counts) == 20
    assert Enum.at(second.counts, 2) == 1
    assert Enum.at(second.counts, 18) == 1
  end

  test "activity/3 keeps a trace in its slice as later traces arrive" do
    controls = [%{seq: 0, kind: :started, at: 0, origin: :ui}]
    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    early = Overview.activity(runs, [{1, 1_500_000}, {1, 2_200_000}])
    later = Overview.activity(runs, [{1, 1_500_000}, {1, 2_200_000}, {1, 9_100_000}])

    assert [%{counts: [0, 1, 1]}] = early.segments
    assert [%{counts: [0, 1, 1, 0, 0, 0, 0, 0, 0, 1]}] = later.segments
  end

  test "activity/3 shows the last minute up to now while a run is going" do
    controls = [%{seq: 0, kind: :started, at: 10_000_000, origin: :ui}]
    runs = Overview.runs(controls, session(status: :running))
    now = DateTime.from_unix!(100_500_000, :microsecond)

    assert %{bucket_ms: 1_000, live?: true, end_us: 101_000_000, segments: [segment]} =
             Overview.activity(runs, [{1, 30_000_000}, {1, 99_200_000}, {1, 99_800_000}], now)

    assert segment.start_us == 41_000_000
    assert length(segment.counts) == 60
    assert Enum.at(segment.counts, 58) == 2
    assert Enum.sum(segment.counts) == 2
  end

  test "activity/3 is nil without runs or, once stopped, without traces" do
    controls = [%{seq: 0, kind: :started, at: 0, origin: :ui}]
    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    assert Overview.activity([], []) == nil
    assert Overview.activity(runs, []) == nil
  end
end
