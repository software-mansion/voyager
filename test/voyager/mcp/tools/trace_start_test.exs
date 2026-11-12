defmodule Voyager.MCP.Tools.TraceStartTest do
  # async: false because the tool drives the global `Tracer` and `Voyager.NodeSession`.
  use Voyager.TraceToolCase, async: false

  alias Voyager.Fakes
  alias Voyager.MCP.Tools.TraceStart

  test "starts the configured session" do
    %{id: id} = configure()

    assert %{"session_id" => ^id, "status" => "running", "total_events" => 0, "events" => sample} =
             json!(TraceStart.execute(%{}, %Frame{}))

    assert [%{"kind" => "configured"}, %{"kind" => "started", "origin" => "mcp"}] = sample
    assert %{status: :running} = Tracer.active()
  end

  test "resumes a stopped session with its events" do
    configure(%{max_events: 2})
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped, stop_reason: :event_limit}, _entries}

    assert %{"status" => "running", "total_events" => 2, "summary" => %{"calls" => 1}} =
             json!(TraceStart.execute(%{}, %Frame{}))
  end

  test "refuses without a configured session" do
    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "no tracing session"

    {:ok, _session} = Tracer.create(:ui)
    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "no function"
  end

  test "refuses a running session" do
    configure()
    {:ok, _session} = Tracer.start(:ui)

    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "trace_watch"
  end

  test "refuses a session of a node Voyager is not connected to" do
    configure()

    Fakes.connect_node!(Fakes.node_session(node: :other@host, node_name: "other@host"))
    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "connected to other@host"

    Fakes.put_session(nil)
    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "connect"
    assert %{status: :idle} = Tracer.active()
  end

  test "returns the agent's refusal" do
    configure(%{module: "Elixir.Voyager.Missing", function: "_", arity: nil})

    assert error!(TraceStart.execute(%{}, %Frame{})) =~ "Could not start tracing"
  end
end
