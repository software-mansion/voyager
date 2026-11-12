defmodule Voyager.MCP.Tools.CreateTraceSessionTest do
  # async: false because the tool reads the global `Voyager.NodeSession` and `Tracer`.
  use Voyager.DataCase, async: false

  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Anubis.Server.InputRequired
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.CreateTraceSession
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture

  @stateless Anubis.Protocol.V2026_07_28
  @forms %{"elicitation" => %{}}

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Fakes.connect_node!(Fakes.node_session(node: node(), node_name: Atom.to_string(node())))
    # The stop's DB write must land before the sandbox owner exits.
    on_exit(fn ->
      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)
      Writer.flush()
    end)

    %{pid: Voyager.Pid.format(self(), :distribution)}
  end

  describe "form" do
    test "asks for the session with the model's arguments prefilled" do
      assert {:reply, %InputRequired{} = input, _frame} =
               execute(%{"function" => "Date.leap_year?/1", "max_rate" => 5})

      assert %{"session" => %{"method" => "elicitation/create", "params" => params}} =
               input.input_requests

      properties = params["requestedSchema"]["properties"]
      assert properties["function"]["default"] == "Date.leap_year?/1"
      assert properties["max_rate"]["default"] == 5
      assert properties["capture_args"]["default"] == false
      refute Map.has_key?(properties["pids"], "default")
      assert params["message"] =~ Atom.to_string(node())
      assert {:set, {:create_trace_session, node, connected_at, _id}} = input.request_state
      assert node == node()
      assert connected_at == NodeSession.current().connected_at
    end

    test "asks again for a form accepted for another node" do
      frame =
        frame(
          %{"session" => accept(%{"function" => "Date"})},
          {:create_trace_session, :a@b, NodeSession.current().connected_at,
           System.unique_integer()}
        )

      assert {:reply, %InputRequired{request_state: {:set, {_, node, _, _id}}}, _frame} =
               execute(%{}, frame)

      assert node == node()
      refute match?(%{status: :running}, Tracer.active())
    end

    test "asks again for a form opened before the node reconnected", %{pid: pid} do
      frame = answered(accept(%{"function" => "Date", "pids" => pid}))
      Fakes.put_session(%{NodeSession.current() | connected_at: DateTime.utc_now()})

      assert {:reply, %InputRequired{}, _frame} = execute(%{}, frame)
      refute match?(%{status: :running}, Tracer.active())
    end

    test "asks again for an answer without its form state" do
      assert {:reply, %InputRequired{}, _frame} =
               execute(%{}, frame(%{"session" => accept(%{"function" => "Date"})}, nil))
    end

    test "rejects a malformed function before showing the form" do
      for function <- ["Date.", "date leap", "Date.leap_year?/x", "Date/1/2"] do
        %{"function" => function} |> execute() |> assert_error()
      end
    end
  end

  describe "answer" do
    test "starts the accepted session and returns its id", %{pid: pid} do
      content = %{"function" => "Date.leap_year?/1", "pids" => pid, "capture_args" => true}

      %{"status" => "started", "session_id" => id} =
        %{} |> execute(answered(accept(content))) |> run()

      assert %{id: ^id, origin: :mcp, status: :running, config: config} = Tracer.active()

      assert %{module: "Elixir.Date", function: "leap_year?", arity: 1, capture: :args} = config
      assert %{processes: :pids, pids: [^pid], max_events: 100, max_time_ms: 60_000} = config
    end

    test "keeps the Elixir prefix of a fully qualified module", %{pid: pid} do
      content = %{"function" => "Elixir.Date.leap_year?/1", "pids" => pid}
      %{"status" => "started"} = %{} |> execute(answered(accept(content))) |> run()

      assert %{module: "Elixir.Date", function: "leap_year?", arity: 1} = Tracer.active().config
    end

    test "parses Erlang functions and traces all processes without pids" do
      Code.ensure_loaded!(:calendar)
      content = %{"function" => "calendar:is_leap_year/1", "pids" => " "}
      %{"status" => "started"} = %{} |> execute(answered(accept(content))) |> run()

      assert %{module: "calendar", function: "is_leap_year", processes: :all, capture: :arity} =
               Tracer.active().config
    end

    test "reports a declined or cancelled form" do
      for action <- ["decline", "cancel"] do
        assert %{"status" => "declined"} =
                 %{} |> execute(answered(%{"action" => action})) |> run()
      end
    end

    test "refuses forbidden modules and limits over the caps" do
      for content <- [
            %{"function" => ":trace.function/4"},
            %{"function" => "Enum.map/2"},
            %{"function" => "Date", "max_events" => 10_001},
            %{"function" => "Date", "max_seconds" => 3_601},
            %{"function" => "Date", "max_rate" => 1_001},
            %{"function" => "Date", "max_events" => nil, "max_seconds" => nil},
            %{"function" => "nope nope"}
          ] do
        %{} |> execute(answered(accept(content))) |> assert_error()
      end

      refute match?(%{origin: :mcp, status: :running}, Tracer.active())
    end

    test "reads max_seconds sent as a string", %{pid: pid} do
      content = %{"function" => "Date", "pids" => pid, "max_seconds" => "60"}
      %{"status" => "started"} = %{} |> execute(answered(accept(content))) |> run()

      assert %{max_time_ms: 60_000} = Tracer.active().config
    end

    test "asks again for a form state already answered", %{pid: pid} do
      frame = answered(accept(%{"function" => "Date", "pids" => pid}))
      %{"status" => "started", "session_id" => id} = %{} |> execute(frame) |> run()

      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)

      assert {:reply, %InputRequired{}, _frame} = execute(%{}, frame)
      assert %{id: ^id} = Tracer.active()
    end

    test "asks again for an accept sent with a declined form state", %{pid: pid} do
      declined = answered(%{"action" => "decline"})
      %{"status" => "declined"} = %{} |> execute(declined) |> run()

      accepted =
        put_in(
          declined.context.input_responses,
          %{"session" => accept(%{"function" => "Date", "pids" => pid})}
        )

      assert {:reply, %InputRequired{}, _frame} = execute(%{}, accepted)
      refute match?(%{status: :running}, Tracer.active())
    end

    test "keeps the previous session when the start fails" do
      {:ok, %{id: id}} = Tracer.create(:ui)
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      content = %{"function" => "Date", "pids" => Voyager.Pid.format(pid, :distribution)}
      %{} |> execute(answered(accept(content))) |> assert_error()

      assert %{id: ^id} = Tracer.active()
    end
  end

  describe "errors" do
    test "needs a connected node" do
      Fakes.put_session(nil)
      %{} |> execute() |> assert_error()
    end

    test "refuses while another session runs", %{pid: pid} do
      %{"status" => "started"} =
        %{}
        |> execute(answered(accept(%{"function" => "Date", "pids" => pid})))
        |> run()

      %{} |> execute() |> assert_error()
    end

    test "needs a client that supports forms" do
      %{} |> execute(%Frame{context: %Context{protocol_module: @stateless}}) |> assert_error()

      %{}
      |> execute(%Frame{
        context: %Context{
          protocol_module: @stateless,
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        }
      })
      |> assert_error()

      %{} |> execute(%Frame{context: %Context{client_capabilities: @forms}}) |> assert_error()
    end
  end

  defp execute(args, frame \\ frame(%{}, nil)) do
    {:ok, params} = CreateTraceSession.mcp_schema(args)
    CreateTraceSession.execute(params, frame)
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

  defp answered(answer),
    do:
      frame(
        %{"session" => answer},
        {:create_trace_session, node(), NodeSession.current().connected_at,
         System.unique_integer()}
      )

  defp accept(content),
    do: %{
      "action" => "accept",
      "content" => Map.merge(%{"max_events" => 100, "max_seconds" => 60}, content)
    }

  defp run(result) do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} = result
    JSON.decode!(json)
  end

  defp assert_error(result) do
    assert {:reply, %Response{isError: true, content: [%{"text" => _}]}, %Frame{}} = result
  end
end
