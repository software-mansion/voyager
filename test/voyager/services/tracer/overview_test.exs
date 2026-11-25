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
    assert interrupted.duration_ms == 0
    assert interrupted.stopped_at == nil
  end

  test "runs/3 subtracts earlier runs' drops from an open run's dropped count" do
    controls = [
      %{seq: 4, kind: :started, at: 20_000_000, origin: :ui},
      %{
        seq: 3,
        kind: :stopped,
        at: 15_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 10,
        dropped: 4
      },
      %{seq: 1, kind: :started, at: 10_000_000, origin: :ui},
      %{seq: 0, kind: :configured, at: 1_000_000, origin: :ui, node: :a@host, config: @first}
    ]

    now = DateTime.from_unix!(25_000_000, :microsecond)

    [first, running] =
      Overview.runs(
        controls,
        session(status: :running, traces: 15, run_traces_before: 10, dropped: 7),
        now
      )

    assert first.dropped == 4
    assert running.dropped == 3

    [_, interrupted] =
      Overview.runs(
        controls,
        session(
          status: :stopped,
          stop_reason: :interrupted,
          traces: 15,
          run_traces_before: 10,
          dropped: 7
        ),
        now
      )

    assert interrupted.dropped == 3
  end

  test "activity/2 keeps a crashed run's traces out of the next run's gap" do
    controls = [
      %{
        seq: 5,
        kind: :stopped,
        at: 30_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 1,
        dropped: 0
      },
      %{seq: 3, kind: :started, at: 20_000_000, origin: :ui},
      %{seq: 0, kind: :started, at: 1_000_000, origin: :ui}
    ]

    runs =
      Overview.runs(
        controls,
        session(
          status: :stopped,
          stop_reason: :stopped,
          stopped_at: DateTime.from_unix!(30_000_000, :microsecond)
        )
      )

    [crashed, later] = runs
    assert crashed.stopped_at == nil
    assert crashed.reason == :interrupted
    assert crashed.traces == 0
    assert crashed.duration_ms == 0
    assert later.traces == 1

    assert %{segments: [first, second]} =
             Overview.activity(runs, [{1, 2_000_000}, {1, 8_000_000}, {2, 22_000_000}])

    assert length(first.counts) > 1
    assert Enum.sum(first.counts) == 2
    assert second.gap_before_ms == 12_000
  end

  test "activity/2 slices each run into fixed-width buckets with the gap between runs" do
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

  test "activity/2 keeps a trace in its slice as later traces arrive" do
    controls = [%{seq: 0, kind: :started, at: 0, origin: :ui}]
    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    early = Overview.activity(runs, [{1, 1_500_000}, {1, 2_200_000}])
    later = Overview.activity(runs, [{1, 1_500_000}, {1, 2_200_000}, {1, 9_100_000}])

    assert [%{counts: [0, 1, 1]}] = early.segments
    assert [%{counts: [0, 1, 1, 0, 0, 0, 0, 0, 0, 1]}] = later.segments
  end

  test "live_activity/2 shows the last minute of live counts up to now" do
    live =
      Overview.count_live(%{}, [
        %{kind: :trace, at: 30_000_000},
        %{kind: :started, at: 99_000_000},
        %{kind: :trace, at: 99_200_000},
        %{kind: :trace, at: 99_800_000}
      ])

    now = DateTime.from_unix!(100_500_000, :microsecond)

    assert %{bucket_ms: 1_000, live?: true, end_us: 101_000_000, segments: [segment]} =
             Overview.live_activity(live, now)

    assert segment.start_us == 41_000_000
    assert length(segment.counts) == 60
    assert Enum.at(segment.counts, 58) == 2
    assert Enum.sum(segment.counts) == 2
  end

  test "count_live/2 keeps only the minute up to the newest trace" do
    live = Overview.count_live(%{}, [%{kind: :trace, at: 1_000_000}])
    assert Overview.count_live(live, []) == live

    live = Overview.count_live(live, [%{kind: :trace, at: 60_500_000}])
    assert live == %{1 => 1, 60 => 1}

    assert Overview.count_live(live, [%{kind: :trace, at: 61_000_000}]) == %{60 => 1, 61 => 1}
  end

  test "activity/2 is nil without runs or without traces" do
    controls = [%{seq: 0, kind: :started, at: 0, origin: :ui}]
    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    assert Overview.activity([], []) == nil
    assert Overview.activity(runs, []) == nil
  end

  test "activity/2 steps up the bucket ladder to keep total buckets within 60" do
    controls = [
      %{
        seq: 1,
        kind: :stopped,
        at: 90_000_000,
        origin: :ui,
        reason: :stopped,
        traces: 2,
        dropped: 0
      },
      %{seq: 0, kind: :started, at: 0, origin: :ui}
    ]

    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :stopped))

    assert %{bucket_ms: 2_000, segments: [segment]} =
             Overview.activity(runs, [{1, 1_000_000}, {1, 89_000_000}])

    assert length(segment.counts) == 45
    assert Enum.sum(segment.counts) == 2
  end

  test "activity/2 fits 60 runs on the smallest fitting rung and caps >60 runs to the newest 60" do
    {controls_60, timestamps_60} = multi_run_fixture(60, 5_000_000)
    runs_60 = Overview.runs(controls_60, session(status: :stopped, stop_reason: :stopped))

    assert %{bucket_ms: 5_000, segments: segments_60} =
             Overview.activity(runs_60, timestamps_60)

    assert length(segments_60) == 60
    assert Enum.sum_by(segments_60, &length(&1.counts)) == 60
    assert Enum.sum_by(segments_60, &Enum.sum(&1.counts)) == 60

    {controls_75, timestamps_75} = multi_run_fixture(75, 5_000_000)
    runs_75 = Overview.runs(controls_75, session(status: :stopped, stop_reason: :stopped))

    assert %{bucket_ms: 5_000, segments: segments_75} =
             Overview.activity(runs_75, timestamps_75)

    assert length(segments_75) == 60

    assert hd(segments_75).start_us ==
             DateTime.to_unix(Enum.at(runs_75, 15).started_at, :microsecond)

    assert hd(segments_75).gap_before_ms == nil
    assert Enum.sum_by(segments_75, &length(&1.counts)) == 60
  end

  test "activity/2 uses multi-day buckets when an open run exceeds 60 days" do
    controls = [%{seq: 0, kind: :started, at: 0, origin: :ui}]
    runs = Overview.runs(controls, session(status: :stopped, stop_reason: :interrupted))
    day_us = 86_400_000_000

    assert %{bucket_ms: bucket_ms, segments: [segment]} =
             Overview.activity(runs, [{1, 1_000_000}, {1, 366 * day_us}])

    assert bucket_ms == 7 * 86_400_000
    assert length(segment.counts) == 53
    assert Enum.sum(segment.counts) == 2
  end

  defp multi_run_fixture(count, duration_us) do
    step_us = duration_us + 5_000_000

    {controls, timestamps} =
      Enum.reduce(1..count, {[], []}, fn index, {controls, timestamps} ->
        start_at = (index - 1) * step_us
        start_seq = (index - 1) * 3

        run_controls = [
          %{
            seq: start_seq + 2,
            kind: :stopped,
            at: start_at + duration_us,
            origin: :ui,
            reason: :stopped,
            traces: 1,
            dropped: 0
          },
          %{seq: start_seq, kind: :started, at: start_at, origin: :ui}
        ]

        {run_controls ++ controls, [{index, start_at + 1_000_000} | timestamps]}
      end)

    {controls, Enum.reverse(timestamps)}
  end

  test "runs/3 pairs controls into runs, each with its config and its own traces and drops" do
    args = %{@first | capture: :args}

    controls = [
      %{seq: 5, kind: :started, at: 30_000_000, origin: :mcp},
      %{seq: 4, kind: :configured, at: 25_000_000, origin: :ui, node: :a@host, config: args},
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

    session =
      session(config: args, status: :running, traces: 100, run_traces_before: 80, dropped: 5)

    assert [first, second] = Overview.runs(controls, session, DateTime.from_unix!(40, :second))

    assert %{index: 1, reason: :stopped, duration_ms: 10_000, traces: 80, dropped: 2} = first
    assert %{config: @first, previous_config: nil} = first

    assert %{index: 2, reason: :running, duration_ms: 10_000, traces: 20, dropped: 3} = second
    assert %{origin: :mcp, config: ^args, previous_config: @first} = second
  end
end
