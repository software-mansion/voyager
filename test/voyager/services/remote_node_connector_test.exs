defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  import Voyager.TestUtils, only: [isolate_persistent_term: 2]

  alias Voyager.ProxyEpmd
  alias Voyager.Services.RemoteNodeConnector

  @moduletag capture_log: true

  setup do
    isolate_persistent_term(:voyager_epmd_module, ProxyEpmd)
    :ok
  end

  describe "connect/6" do
    test "returns an error when the SSH host is unreachable" do
      result =
        RemoteNodeConnector.connect(
          "nobody",
          "127.0.0.1",
          "node@127.0.0.1",
          "cookie",
          :agent,
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end

    test "rejects a malformed node name before opening any connection" do
      assert {:error, {:invalid_node_name, "no_at_sign"}} =
               RemoteNodeConnector.connect("nobody", "127.0.0.1", "no_at_sign", "cookie", :agent)
    end

    test "returns an error without opening any connection when proxy_epmd is not active" do
      :persistent_term.put(:voyager_epmd_module, :erl_epmd)

      assert {:error, :proxy_epmd_not_active} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "node@127.0.0.1",
                 "cookie",
                 :agent
               )
    end
  end
end
