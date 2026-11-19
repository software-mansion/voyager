defmodule Voyager.MCP.Tools.StartDemoTest do
  # async: false because the tool drives the global `Voyager.NodeSession` and `DemoNode`.
  use Voyager.DataCase, async: false

  import Voyager.TestUtils

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.StartDemo
  alias Voyager.NodeSession
  alias Voyager.Services.DemoNode

  @node :"voyager_demo@127.0.0.1"
  @node_name "voyager_demo@127.0.0.1"

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  test "starts the demo node without returning its cookie" do
    start_demo_node!()

    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             StartDemo.execute(%{}, %Frame{})

    %{peer: peer, cookie: cookie} = :sys.get_state(DemoNode)
    assert is_pid(peer)
    assert %{"status" => "started", "node" => @node_name} = JSON.decode!(json)
    refute json =~ cookie
  end

  test "reports the demo it is connected to without restarting it" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    peer = :sys.get_state(DemoNode).peer
    Fakes.connect_node!(Fakes.node_session(node: @node, node_name: @node_name))

    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             StartDemo.execute(%{}, %Frame{})

    assert JSON.decode!(json) == %{"status" => "connected", "node" => @node_name}
    assert :sys.get_state(DemoNode).peer == peer
  end

  test "refuses while connected to another node and points at disconnect" do
    start_demo_node!()
    Fakes.connect_node!(Fakes.node_session(node_name: "shop@10.0.4.12"))

    assert {:reply, %Response{isError: true, content: [%{"text" => message}]}, %Frame{}} =
             StartDemo.execute(%{}, %Frame{})

    assert message =~ "shop@10.0.4.12"
    assert message =~ "`disconnect`"
    assert :sys.get_state(DemoNode).peer == nil
  end

  test "returns an error outside a release" do
    start_demo_node!(exec: nil)

    assert {:reply, %Response{isError: true}, %Frame{}} = StartDemo.execute(%{}, %Frame{})
  end
end
