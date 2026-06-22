defmodule Voyager.MCP.Tools.NodeInfoTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.NodeInfo

  setup do
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, Voyager.ErpcMock) end)
    :ok
  end

  test "returns an error when no node is connected" do
    Fakes.put_session(nil)

    assert {:reply, %Response{isError: true, content: content}, %Frame{}} =
             NodeInfo.execute(%{}, %Frame{})

    assert [%{"type" => "text", "text" => "Not connected to any node"}] = content
  end

  test "returns a JSON snapshot when a node session is active" do
    node = Node.self()

    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    assert {:reply, %Response{isError: false, content: content}, %Frame{}} =
             NodeInfo.execute(%{}, %Frame{})

    [%{"type" => "text", "text" => json}] = content
    assert %{"node" => node_string, "system" => %{"otp_release" => _}} = JSON.decode!(json)
    assert node_string == Atom.to_string(node)
  end

  test "returns an error when the snapshot fetch fails" do
    Fakes.connect_node!(
      Fakes.node_session(node: :"nonexistent@127.0.0.1", node_name: "nonexistent@127.0.0.1")
    )

    assert {:reply, %Response{isError: true, content: content}, %Frame{}} =
             NodeInfo.execute(%{}, %Frame{})

    assert [%{"type" => "text", "text" => "fetch failed: :noconnection"}] = content
  end
end
