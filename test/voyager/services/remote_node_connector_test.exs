defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.RemoteNodeConnector

  @moduletag capture_log: true

  describe "connect/5" do
    test "returns an error when the SSH host is unreachable" do
      result =
        RemoteNodeConnector.connect(
          "nobody",
          "127.0.0.1",
          "node@127.0.0.1",
          :agent,
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end

    test "rejects a malformed node name before opening any connection" do
      assert {:error, {:invalid_node_name, "no_at_sign"}} =
               RemoteNodeConnector.connect("nobody", "127.0.0.1", "no_at_sign", :agent)
    end

    test "rejects an invalid epmd_prefix before opening any connection" do
      assert {:error, {:invalid_epmd_prefix, "; rm -rf /"}} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "node@127.0.0.1",
                 :agent,
                 epmd_prefix: "; rm -rf /"
               )
    end
  end

  describe "split_node_name/1" do
    test "splits name@host into its parts" do
      assert {:ok, "myapp", "10.0.0.5"} = RemoteNodeConnector.split_node_name("myapp@10.0.0.5")
    end

    test "keeps the host intact when it contains an @-free remainder" do
      assert {:ok, "myapp", "host@weird"} =
               RemoteNodeConnector.split_node_name("myapp@host@weird")
    end

    test "errors when there is no @ separator" do
      assert {:error, {:invalid_node_format, "noatsign"}} =
               RemoteNodeConnector.split_node_name("noatsign")
    end
  end
end
