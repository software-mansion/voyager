defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  import Voyager.TestUtils

  alias Voyager.Services.RemoteNodeConnector
  alias Voyager.Test.SshServer

  @moduletag capture_log: true

  setup :enable_proxy_epmd

  describe "connect/6" do
    test "returns an error when the SSH host is unreachable" do
      result =
        RemoteNodeConnector.connect(
          "nobody",
          "127.0.0.1",
          "node@127.0.0.1",
          "cookie",
          {:agent, nil},
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end

    @tag :tmp_dir
    test "returns the SSH auth error for a wrong password", %{tmp_dir: tmp_dir} do
      Application.put_env(:voyager, :known_hosts_path, Path.join(tmp_dir, "known_hosts"))
      on_exit(fn -> Application.delete_env(:voyager, :known_hosts_path) end)
      %{port: port, fingerprint: fingerprint} = SshServer.start!({127, 0, 0, 1})

      assert {:error, ~c"Unable to connect using the available authentication methods"} =
               RemoteNodeConnector.connect(
                 SshServer.user(),
                 "127.0.0.1",
                 "node@127.0.0.1",
                 "cookie",
                 {:password, "wrong"},
                 ssh_port: port,
                 host_key: fingerprint
               )
    end

    test "rejects a malformed node name before opening any connection" do
      assert {:error, {:invalid_node_name, "no_at_sign"}} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "no_at_sign",
                 "cookie",
                 {:agent, nil}
               )
    end

    test "returns an error without opening any connection when proxy_epmd is not active" do
      :persistent_term.put(:voyager_epmd_module, :erl_epmd)

      assert {:error, :proxy_epmd_not_active} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "node@127.0.0.1",
                 "cookie",
                 {:agent, nil}
               )
    end
  end
end
