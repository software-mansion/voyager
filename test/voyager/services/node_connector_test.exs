defmodule Voyager.Services.NodeConnectorTest do
  use Voyager.DataCase, async: false

  alias Voyager.Services.NodeConnector

  @moduletag capture_log: true

  setup do
    started_here? = not Node.alive?()

    on_exit(fn ->
      if started_here? and Node.alive?(), do: :net_kernel.stop()
    end)

    :ok
  end

  describe "connect/3" do
    test "returns :node_not_registered when the host's epmd has no matching name" do
      assert {:error, :node_not_registered} =
               NodeConnector.connect("definitely_not_a_registered_node@127.0.0.1", "cookie")
    end
  end
end
