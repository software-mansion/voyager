defmodule Voyager.MCP.Tools.TraceHistoryTest do
  # async: false because the tool reads the global `Tracer`.
  use Voyager.TraceToolCase, async: false

  alias Voyager.MCP.Tools.TraceHistory

  test "lists the active session first, then the saved ones, each once" do
    %{id: saved} = configure(%{}, save: true)
    assert %{"sessions" => [%{"session_id" => ^saved, "status" => "idle"}]} = history(%{})

    %{id: active} = configure()

    assert %{"sessions" => [%{"session_id" => ^active}, %{"session_id" => ^saved} = listed]} =
             history(%{})

    assert %{"target" => "Date.leap_year?/1", "capture" => "args", "total_events" => 0} = listed
  end

  test "reads a running session page by page" do
    %{id: id} = configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)

    assert %{"status" => "running", "events" => events, "next_since" => 3, "more" => true} =
             history(%{"session_id" => id, "limit" => 3})

    assert Enum.map(events, & &1["seq"]) == [0, 1, 2]
    assert %{"summary" => %{"calls" => 1}, "untrusted" => _} = history(%{"session_id" => id})

    trace_calls(1)

    assert %{"events" => events, "next_since" => 6, "more" => false} =
             history(%{"session_id" => id, "since" => 3})

    assert Enum.map(events, & &1["kind"]) == ["return", "call", "return"]
    assert %{"events" => [], "next_since" => 6} = history(%{"session_id" => id, "since" => 6})
  end

  test "marks a page missing events evicted from an unsaved session" do
    %{id: id} = configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(260)

    assert %{"truncated" => true, "summary" => %{"calls" => 260}, "events" => events} =
             history(%{"session_id" => id, "limit" => 3})

    assert [%{"seq" => 0}, %{"seq" => 1}, %{"seq" => seq}] = events
    assert seq > 2
  end

  test "reads a saved session that is no longer active" do
    %{id: id} = configure(%{capture: :arity}, save: true)
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    Tracer.stop(:ui)
    assert_receive {:session_entries, %{status: :stopped}, _entries}
    {:ok, _session} = Tracer.create(:ui)

    report = history(%{"session_id" => id})

    assert %{"status" => "stopped", "summary" => %{"calls" => 1}, "events" => events} = report

    assert Enum.map(events, & &1["kind"]) == [
             "configured",
             "started",
             "call",
             "return",
             "stopped"
           ]

    refute Map.has_key?(report, "untrusted")
  end

  test "refuses an unknown session" do
    assert {:reply, response, _frame} = execute(%{"session_id" => 424_242})
    assert error!({:reply, response, %Frame{}}) =~ "No tracing session"
  end

  defp history(args), do: args |> execute() |> json!()

  defp execute(args) do
    {:ok, params} = TraceHistory.mcp_schema(args)
    TraceHistory.execute(params, %Frame{})
  end
end
