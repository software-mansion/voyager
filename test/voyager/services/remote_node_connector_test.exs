defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  import Voyager.TestUtils

  alias Voyager.Services.RemoteNodeConnector

  @moduletag capture_log: true

  setup :enable_proxy_epmd

  describe "tunnel_target/1" do
    test "an IPv6 literal node host is the tunnel target itself" do
      assert RemoteNodeConnector.tunnel_target("::1") == ~c"::1"
      assert RemoteNodeConnector.tunnel_target("fdaa:0:1::2") == ~c"fdaa:0:1::2"
    end

    test "IPv4 literals and hostnames tunnel to the remote v4 loopback" do
      assert RemoteNodeConnector.tunnel_target("10.0.0.5") == ~c"127.0.0.1"
      assert RemoteNodeConnector.tunnel_target("example.com") == ~c"127.0.0.1"
    end
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
