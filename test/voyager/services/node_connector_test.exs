defmodule Voyager.Services.NodeConnectorTest do
  use Voyager.DataCase, async: false

  alias Voyager.Services.NodeConnector

  @moduletag capture_log: true

  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  describe "connect/3" do
    test "returns :node_not_registered when the host's epmd has no matching name" do
      assert {:error, :node_not_registered} =
               NodeConnector.connect("definitely_not_a_registered_node@127.0.0.1", "cookie")
    end

    test "surfaces a network-specific error when the host cannot be reached" do
      result = NodeConnector.connect("nobody@192.0.2.1", "cookie")

      assert match?({:error, :epmd_timeout}, result) or match?({:error, {:epmd_error, _}}, result)
    end
  end
end
