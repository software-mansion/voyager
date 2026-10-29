defmodule Voyager.MCP.Tools.DisconnectTest do
  # async: false because the tool drives the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.Disconnect
  alias Voyager.NodeSession

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: "shop@10.0.4.12"))
    :ok
  end

  test "drops the session and names the node" do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             Disconnect.execute(%{}, %Frame{})

    assert JSON.decode!(json) == %{"status" => "disconnected", "node" => "shop@10.0.4.12"}
    assert NodeSession.current() == nil
  end

  test "returns an error when no node is connected" do
    Fakes.put_session(nil)

    assert {:reply, %Response{isError: true}, %Frame{}} = Disconnect.execute(%{}, %Frame{})
  end
end
