defmodule Voyager.MCP.Tools.TraceHistoryTest do
  # async: false because the tool reads the global `Tracer`.
  use Voyager.TraceToolCase, async: false

  alias Voyager.MCP.Tools.TraceHistory
  alias Voyager.MCP.Tools.TraceReport

  test "lists the active session first, then the saved ones, each once" do
    %{id: saved} = configure(%{}, save: true)
    assert %{"sessions" => [%{"session_id" => ^saved, "status" => "idle"}]} = history(%{})

    %{id: active} = configure()

    assert %{"sessions" => [%{"session_id" => ^active}, %{"session_id" => ^saved} = listed]} =
             history(%{})

    assert %{"target" => "Date.leap_year?/1", "capture" => "args", "total_events" => 0} = listed
  end

  test "lists 20 saved sessions besides the active one, then older ones past the cursor" do
    for _ <- 1..22, do: {:ok, _session} = Tracer.create(:ui, save: true)

    assert %{"sessions" => [%{"session_id" => active} | saved], "next_before_id" => before_id} =
             history(%{})

    assert length(saved) == 20
    refute active in Enum.map(saved, & &1["session_id"])

    assert %{"sessions" => [%{"session_id" => older}]} =
             page = history(%{"before_id" => before_id})

    assert older < before_id
    refute Map.has_key?(page, "next_before_id")
  end

  test "lists only the sessions on the given node" do
    %{id: on_node} = configure(%{}, save: true)
    {:ok, _session} = Tracer.create(:ui, save: true)

    assert %{"sessions" => [%{"session_id" => ^on_node}]} =
             history(%{"node" => Atom.to_string(node())})

    assert %{"sessions" => []} = history(%{"node" => "other@host"})
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

  test "reads a saved session that is no longer active, with return values but no arguments" do
    %{id: id} = configure(%{capture: :arity}, save: true)
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    Tracer.stop(:ui)
    assert_receive {:session_entries, %{status: :stopped}, _entries}
    {:ok, _session} = Tracer.create(:ui)

    report = history(%{"session_id" => id})

    assert %{"status" => "stopped", "summary" => %{"calls" => 1}, "events" => events} = report
    assert %{"untrusted" => _, "runs" => [%{"run" => 1, "reason" => "stopped"}]} = report
    refute Map.has_key?(report, "last_run_summary")

    assert [
             %{"kind" => "configured"},
             %{"kind" => "started"},
             %{"kind" => "call"} = call,
             %{"kind" => "return", "value" => "false"},
             %{"kind" => "stopped"}
           ] = events

    refute Map.has_key?(call, "args")
  end

  test "reports each run, with its config changes, and the last run's summary" do
    %{id: id} = configure(%{max_events: 2})
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped}, _entries}

    {:ok, _session} =
      Tracer.configure(node(), config_attrs(%{capture: :arity, max_events: 2}), :ui)

    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped, traces: 4}, _entries}

    assert %{"runs" => [first, second], "summary" => %{"calls" => 2}} =
             report = history(%{"session_id" => id})

    assert %{"run" => 1, "events" => 2, "reason" => "event_limit", "config" => config} = first
    assert config == %{"capture" => "args"}
    assert %{"run" => 2, "events" => 2} = second
    refute Map.has_key?(second, "config")
    assert %{"last_run_summary" => %{"calls" => 1}} = report
  end

  test "searches a session's events, newest first, past the cursor" do
    %{id: id} = configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(3)

    assert %{"events" => [%{"kind" => "call", "args" => args}], "total_matches" => 1} =
             report = history(%{"session_id" => id, "query" => "2002"})

    assert args =~ "2002"
    assert %{"searched" => _, "more" => false} = report

    assert %{"events" => [newest, older], "next_before" => before, "more" => true} =
             history(%{"session_id" => id, "query" => "leap_year", "limit" => 2})

    assert newest["seq"] > older["seq"]
    assert before == older["seq"]

    assert %{"events" => [next, _], "more" => true} =
             history(%{
               "session_id" => id,
               "query" => "leap_year",
               "before" => before,
               "limit" => 2
             })

    assert next["seq"] < before
  end

  test "warns about the payloads an earlier run captured, whatever the current config" do
    %{id: id} = configure(%{max_events: 2})
    refute Map.has_key?(history(%{"session_id" => id}), "untrusted")

    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped}, _entries}

    {:ok, _session} =
      Tracer.configure(node(), config_attrs(%{capture: :arity, return_trace: false}), :ui)

    assert %{"untrusted" => _, "events" => events} = history(%{"session_id" => id})
    assert Enum.any?(events, &Map.has_key?(&1, "args"))
  end

  test "refuses an unknown session" do
    assert {:reply, response, _frame} = execute(%{"session_id" => 424_242})
    assert error!({:reply, response, %Frame{}}) =~ "No tracing session"
  end

  test "refuses ids and seqs past 64 bits before they reach the database" do
    too_big = TraceReport.max_integer() + 1

    for args <- [
          %{"session_id" => too_big},
          %{"session_id" => -too_big},
          %{"session_id" => 1, "since" => too_big},
          %{"session_id" => 1, "query" => "x", "before" => too_big},
          %{"before_id" => too_big}
        ] do
      assert {:error, _errors} = TraceHistory.mcp_schema(args)
    end
  end

  defp history(args), do: args |> execute() |> json!()

  defp execute(args) do
    {:ok, params} = TraceHistory.mcp_schema(args)
    TraceHistory.execute(params, %Frame{})
  end
end
