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

  test "says what to do about the agent's refusals instead of showing the raw term" do
    assert TraceReport.start_error(:no_session) =~ "create_trace_session"
    assert TraceReport.start_error({:noproc, self()}) =~ "#{Voyager.Pid.format(self())} is not"
    assert TraceReport.start_error({:not_loaded, Voyager.Missing}) =~ "Voyager.Missing is not"
    assert TraceReport.start_error(:no_function_matched) =~ "`scope` `local`"
  end
end
