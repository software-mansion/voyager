defmodule VoyagerWeb.TracingSessionLive.StatsTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.TracingSessionLive.Stats

  @started ~U[2026-01-01 12:00:00Z]

  test "shows plain numbers when no limits are set" do
    session = running(%{traces: 3_214}, %{max_events: nil, max_rate: nil, max_time_ms: nil})

    assert [events, rate, dropped, run_time, storage] =
             Stats.cells(session, [4, 38], at(108), 100)

    assert events == %{key: :events, label: "Events this run", value: "3,214"}
    assert %{key: :rate, value: "38", unit: "/s", spark: [10, 100]} = rate
    assert dropped == %{key: :dropped, label: "Dropped", value: "0", tone: nil}
    assert run_time == %{key: :run_time, label: "Run time", value: "1:48"}
    assert %{value: "Not saved", unit: "newest 500"} = storage
  end

  test "measures against every limit that is set" do
    session =
      running(%{traces: 3_214}, %{max_events: 10_000, max_rate: 1_000, max_time_ms: 300_000})

    assert [events, rate, _dropped, auto_stop, _storage] =
             Stats.cells(session, [380], at(108), 100)

    assert %{unit: "/ 10,000", bar: [{"bg-primary", 32}]} = events
    assert %{value: "380", unit: "/s of 1,000", spark: [38]} = rate
    assert %{key: :auto_stop, value: "3:12", bar: [{"bg-success", 64}]} = auto_stop
  end

  test "counts only the current run of a resumed session" do
    session = running(%{traces: 1_500, run_traces_before: 1_000}, %{max_events: 1_000})

    assert [%{value: "500", bar: [{_fill, 50}]} | _rest] = Stats.cells(session, [], at(10), 100)
  end

  test "shows the stop reason and run time of a stopped session" do
    session =
      running(%{status: :stopped, stop_reason: :node_down, dropped: 412, stopped_at: at(38)}, %{
        max_time_ms: 300_000
      })

    assert [_events, reason, dropped, run_time, _storage] =
             Stats.cells(session, [5], at(500), 100)

    assert %{
             key: :stop_reason,
             value: "Node went down",
             tip: "Node went down",
             prose: true,
             tone: "text-warning"
           } = reason

    assert %{value: "412", tone: "text-warning"} = dropped
    assert %{key: :run_time, value: "0:38", unit: "of 5:00", bar: [{_fill, 12}]} = run_time
  end

  test "keeps a stop on request untoned" do
    session = running(%{status: :stopped, stop_reason: :stopped, stopped_at: at(1)})

    assert [_events, %{value: "Stopped on request", tone: nil} | _rest] =
             Stats.cells(session, [], at(1), 100)
  end

  test "clamps the bars to 0-100" do
    session = running(%{traces: 2_000}, %{max_events: 1_000, max_time_ms: 60_000})

    assert [%{bar: [{_fill, 100}]}, _rate, _dropped, auto_stop, _storage] =
             Stats.cells(session, [], at(90), 100)

    assert %{value: "0:00", bar: [{_fill, 0}]} = auto_stop
  end

  test "shows a saved session's storage beside the other saved sessions' share of the limit" do
    session = running(%{save: true, bytes: 18_400_000, storage_limit: 60_000_000})

    assert %{
             value: "18.4 MB",
             unit: "of 100 MB",
             bar: [{_others, 40}, {_this, 18}],
             tip: [
               {"This session", "18.4 MB"},
               {"Other saved sessions", "40.0 MB"},
               {"Free", "41.6 MB"}
             ]
           } =
             session
             |> Stats.cells([], at(1), 100)
             |> List.last()

    assert %{bar: [{_others, 0}, {_this, 1}]} =
             session
             |> Stats.cells([], at(1), 0)
             |> List.last()
  end

  test "shows a small session's size in KB, rounded up, and keeps it visible on the bar" do
    session = running(%{save: true, bytes: 1_200, storage_limit: 100_000_000})

    assert %{
             value: "2 KB",
             bar: [{_others, 0}, {_this, 1}],
             tip: [_this_size, {"Other saved sessions", "0 KB"}, _free]
           } =
             session
             |> Stats.cells([], at(1), 100)
             |> List.last()
  end

  test "scales the sparkline to the larger of max rate and the busiest tick" do
    below_limit = running(%{}, %{max_rate: 200})
    above_limit = running(%{}, %{max_rate: 50})

    assert [_events, %{spark: [0, 25, 50]} | _rest] =
             Stats.cells(below_limit, [0, 50, 100], at(1), 100)

    assert [_events, %{spark: [0, 50, 100]} | _rest] =
             Stats.cells(above_limit, [0, 50, 100], at(1), 100)

    assert [_events, %{value: "0", spark: [0, 0]} | _rest] =
             Stats.cells(running(%{}), [0, 0], at(1), 100)
  end

  defp running(fields, config \\ %{}) do
    config = struct!(%Config{module: "Elixir.Date", function: "leap_year?", arity: 1}, config)

    struct!(
      %Session{id: 1, origin: :ui, created_at: @started},
      Map.merge(%{status: :running, run_started_at: @started, config: config}, fields)
    )
  end

  defp at(seconds), do: DateTime.add(@started, seconds)
end
