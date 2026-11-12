defmodule Voyager.MCP.Tools.TraceReportTest do
  # async: false because the report reads the global `Tracer`.
  use Voyager.TraceToolCase, async: false

  alias Voyager.MCP.Tools.TraceReport

  test "reports a run that ended after the given snapshot as stopped" do
    configure(%{max_events: 2})
    {:ok, running} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped}, _entries}

    assert {:ok, %{status: :stopped, stop_reason: :event_limit, total_events: 2}} =
             TraceReport.report(running)
  end
end
