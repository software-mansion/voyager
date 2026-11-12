defmodule Voyager.MCP.Tools.TraceStopTest do
  # async: false because the tool drives the global `Tracer` and `Voyager.NodeSession`.
  use Voyager.TraceToolCase, async: false

  alias Voyager.MCP.Tools.TraceStop

  test "stops the running session and returns its final report" do
    %{id: id} = configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(2)

    report = json!(TraceStop.execute(%{}, %Frame{}))

    assert %{
             "session_id" => ^id,
             "status" => "stopped",
             "stop_reason" => "stopped",
             "target" => "Date.leap_year?/1",
             "total_events" => 4,
             "untrusted" => _,
             "summary" => %{
               "calls" => 2,
               "returns" => 2,
               "by_function" => [%{"function" => "Date.leap_year?/1", "calls" => 2}],
               "by_process" => [%{"calls" => 2}],
               "slowest" => [%{"kind" => "return", "duration_us" => _} | _]
             }
           } = report

    assert [%{"kind" => "configured"}, %{"kind" => "started"} | events] = report["events"]
    assert [%{"kind" => "call", "args" => "[~D[2001-01-01]]"}, %{"value" => "false"} | _] = events
    assert %{"kind" => "stopped", "origin" => "mcp"} = List.last(events)
    assert %{status: :stopped} = Tracer.active()
  end

  test "returns a stopped session's report unchanged" do
    configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    first = json!(TraceStop.execute(%{}, %Frame{}))

    assert json!(TraceStop.execute(%{}, %Frame{})) == first
  end

  test "leaves arguments and return values out unless the session captured them" do
    configure(%{capture: :arity})
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)

    report = json!(TraceStop.execute(%{}, %Frame{}))

    refute Map.has_key?(report, "untrusted")
    refute Enum.any?(report["events"], &(Map.has_key?(&1, "args") or Map.has_key?(&1, "value")))
  end

  test "reports a saved session from the database" do
    %{id: id} = configure(%{}, save: true)
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(2)

    assert %{"session_id" => ^id, "summary" => %{"calls" => 2, "returns" => 2}} =
             json!(TraceStop.execute(%{}, %Frame{}))
  end

  test "refuses without a session or before it starts" do
    assert error!(TraceStop.execute(%{}, %Frame{})) =~ "no tracing session"

    configure()
    assert error!(TraceStop.execute(%{}, %Frame{})) =~ "trace_start"
  end
end
