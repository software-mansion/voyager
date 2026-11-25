defmodule Voyager.MCP.Tools.TraceConfigureTest do
  # async: false because the tool drives the global `Tracer` and `Voyager.NodeSession`.
  use Voyager.TraceToolCase, async: false

  alias Anubis.Server.Context
  alias Anubis.Server.InputRequired
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.TraceConfigure
  alias Voyager.MCP.Tools.TraceForm
  alias Voyager.NodeSession

  @stateless Anubis.Protocol.V2026_07_28
  @forms %{"elicitation" => %{}}

  test "asks with the session's config prefilled and the proposed changes on top" do
    %{id: id} = configure(%{max_events: 10})

    assert {:reply, %InputRequired{} = input, _frame} =
             execute(%{"session_id" => id, "max_rate" => 5, "scope" => "local"})

    assert %{"session" => %{"params" => %{"message" => message, "requestedSchema" => schema}}} =
             input.input_requests

    assert message =~ "#{id}"
    properties = schema["properties"]
    assert properties["function"]["default"] == "Date.leap_year?/1"
    assert properties["capture_args"]["default"] == true
    assert properties["max_events"]["default"] == 10
    assert properties["max_rate"]["default"] == 5
    assert properties["scope"]["default"] == "local"
    refute Map.has_key?(properties, "save")
    assert {:set, {:trace_configure, _node, _connected_at, ^id, "", _nonce}} = input.request_state
  end

  test "applies the accepted form to a stopped session, which goes back to idle" do
    %{id: id} = configure(%{max_events: 2})
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    assert_receive {:session_entries, %{status: :stopped}, _entries}

    content = %{"function" => "Date.leap_year?/1", "pids" => pid(), "max_events" => 4}

    assert %{"session_id" => ^id, "status" => "idle", "next" => _, "limits" => limits} =
             json!(execute(%{"session_id" => id}, answered(id, accept(content))))

    assert limits == %{"max_events" => 4, "max_time_ms" => 60_000}
    assert %{status: :idle, config: %{max_events: 4, capture: :arity}} = Tracer.active()
  end

  test "loads a saved session that is not active before applying the form" do
    %{id: saved} = configure(%{}, save: true)
    {:ok, _session} = Tracer.create(:ui)
    content = %{"function" => "Date.leap_year?/1", "pids" => pid()}

    assert %{"session_id" => ^saved} =
             json!(execute(%{"session_id" => saved}, answered(saved, accept(content))))

    assert %{id: ^saved, save: true} = Tracer.active()
  end

  test "says a failed configure of a saved session discarded the unsaved one it replaced" do
    %{id: saved} = configure(%{}, save: true)
    %{id: unsaved} = configure()
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    Tracer.stop(:ui)
    assert_receive {:session_entries, %{id: ^unsaved, status: :stopped}, _entries}

    frame = answered(saved, accept(%{"function" => "Date.leap_year?/1", "pids" => pid()}))
    Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

    Mox.expect(Voyager.ErpcMock, :call, fn _node, :lists, :map, _args, _timeout ->
      :erlang.error({:erpc, :noconnection})
    end)

    message = error!(execute(%{"session_id" => saved}, frame))

    assert message =~ "unsaved session #{unsaved} and its 2 events were discarded"
    assert %{id: ^saved} = Tracer.active()
  end

  test "asks again for an answer meant for another session" do
    %{id: id} = configure()
    content = %{"function" => "Date", "pids" => pid(), "max_events" => 4}

    assert {:reply, %InputRequired{}, _frame} =
             execute(%{"session_id" => id}, answered(id + 1, accept(content)))

    assert %{config: %{max_events: 1_000}} = Tracer.active()
  end

  test "asks again when the session it would discard changed after the form was shown" do
    %{id: saved} = configure(%{}, save: true)
    %{id: unsaved} = configure()
    frame = answered(saved, accept(%{"function" => "Date.leap_year?/1", "pids" => pid()}))

    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)
    Tracer.stop(:ui)
    assert_receive {:session_entries, %{id: ^unsaved, status: :stopped}, _entries}

    assert {:reply, %InputRequired{input_requests: %{"session" => request}}, _frame} =
             execute(%{"session_id" => saved}, frame)

    assert request["params"]["message"] =~ "discards"
    assert %{id: ^unsaved} = Tracer.active()
  end

  test "refuses while another session runs, rather than asking again as its events grow" do
    %{id: saved} = configure(%{}, save: true)
    configure()
    {:ok, _session} = Tracer.start(:ui)

    assert error!(execute(%{"session_id" => saved})) =~ "trace_stop"
  end

  test "refuses a running or unknown session" do
    %{id: id} = configure()
    assert error!(execute(%{"session_id" => 424_242})) =~ "No tracing session"

    {:ok, _session} = Tracer.start(:ui)
    assert error!(execute(%{"session_id" => id})) =~ "trace_stop"
  end

  test "refuses a session of a node Voyager is not connected to" do
    %{id: id} = configure()
    Fakes.connect_node!(Fakes.node_session(node: :other@host, node_name: "other@host"))

    assert error!(execute(%{"session_id" => id})) =~ "connected to other@host"
  end

  test "reports a declined form" do
    %{id: id} = configure()

    assert %{"status" => "declined"} =
             json!(execute(%{"session_id" => id}, answered(id, %{"action" => "decline"})))
  end

  defp execute(args, frame \\ frame(%{}, nil)) do
    {:ok, params} = TraceConfigure.mcp_schema(args)
    TraceConfigure.execute(params, frame)
  end

  defp frame(responses, state) do
    %Frame{
      context: %Context{
        protocol_module: @stateless,
        client_capabilities: @forms,
        input_responses: responses,
        request_state: state
      }
    }
  end

  defp answered(id, answer) do
    state =
      {:trace_configure, node(), NodeSession.current().connected_at, id,
       TraceForm.discard_warning(Tracer.active(), id), System.unique_integer()}

    frame(%{"session" => answer}, state)
  end

  defp accept(content),
    do: %{"action" => "accept", "content" => Map.merge(%{"max_seconds" => 60}, content)}

  defp pid, do: Voyager.Pid.format(self(), :distribution)
end
