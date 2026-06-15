defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector
  alias Voyager.SshdFixture

  @moduletag capture_log: true

  describe "parse_port/2" do
    test "parses a single-node epmd -names output" do
      output = """
      epmd: up and running on port 4369 with data:
      name app at port 41234
      """

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "app")
    end

    test "picks the requested name out of multiple" do
      output = """
      epmd: up and running on port 4369 with data:
      name other at port 99
      name app at port 41234
      name third at port 55555
      """

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "app")
    end

    test "returns :node_not_found when the name is absent" do
      output = "epmd: up and running on port 4369\nname other at port 99\n"

      assert {:error, {:node_not_found, "missing", ^output}} =
               RemoteNodeConnector.parse_port(output, "missing")
    end

    test "returns :node_not_found on empty output" do
      assert {:error, {:node_not_found, "x", ""}} = RemoteNodeConnector.parse_port("", "x")
    end

    test "does not match a name that is only a prefix of another" do
      output = "name appserver at port 41234\n"

      assert {:error, {:node_not_found, "app", _}} =
               RemoteNodeConnector.parse_port(output, "app")
    end

    test "escapes regex metacharacters in the node name" do
      output = "name a.b+c at port 41234\n"

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "a.b+c")
      assert {:error, _} = RemoteNodeConnector.parse_port(output, "axbxc")
    end
  end

  describe "connect/5" do
    test "returns an error when the SSH host is unreachable" do
      result =
        RemoteNodeConnector.connect(
          "nobody",
          "127.0.0.1",
          "no_such_node",
          :agent,
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end

    test "rejects unsupported auth methods" do
      assert {:error, :auth_method_unsupported} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "node",
                 {:password, "x"},
                 ssh_port: 1
               )

      assert {:error, :auth_method_unsupported} =
               RemoteNodeConnector.connect(
                 "nobody",
                 "127.0.0.1",
                 "node",
                 {:key, "/tmp/k", "passphrase"},
                 ssh_port: 1
               )
    end
  end

  describe "with real sshd" do
    @describetag :integration

    setup do
      ctx = SshdFixture.start!()
      kh_path = SshdFixture.install_host_key!(ctx)

      previous = Application.get_env(:voyager, :known_hosts_path)
      Application.put_env(:voyager, :known_hosts_path, kh_path)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:voyager, :known_hosts_path, previous),
          else: Application.delete_env(:voyager, :known_hosts_path)

        SshdFixture.stop!(ctx)
      end)

      {:ok, sshd: ctx}
    end

    test "discover_dist_port parses the port from a node present in epmd output", %{sshd: ctx} do
      assert {:ok, 41_234} =
               RemoteNodeConnector.discover_dist_port(
                 ctx.user,
                 ctx.host,
                 ctx.port,
                 {:key, ctx.key_path},
                 "myapp"
               )
    end

    test "discover_dist_port returns :node_not_found when the node is absent", %{sshd: ctx} do
      assert {:error, {:node_not_found, "missing", _}} =
               RemoteNodeConnector.discover_dist_port(
                 ctx.user,
                 ctx.host,
                 ctx.port,
                 {:key, ctx.key_path},
                 "missing"
               )
    end

    test "connect/5 returns auth failure when the key is wrong", %{sshd: ctx} do
      bad_key = generate_unrelated_key!(ctx.dir)

      assert {:error, _} =
               RemoteNodeConnector.connect(
                 ctx.user,
                 ctx.host,
                 "myapp",
                 {:key, bad_key, nil},
                 ssh_port: ctx.port
               )
    end

    test "TunnelRegistry cleans up when the tunnel pid exits" do
      node_key = ~c"stoptest_#{System.unique_integer([:positive])}"
      {:ok, fake_pid} = Agent.start(fn -> :ok end)
      :ok = TunnelRegistry.register(node_key, 12_345, fake_pid)

      assert [{^node_key, _}] = :ets.lookup(:proxy_epmd, node_key)

      ref = Process.monitor(fake_pid)
      Agent.stop(fake_pid)
      assert_receive {:DOWN, ^ref, :process, ^fake_pid, _}

      _ = :sys.get_state(TunnelRegistry)
      assert :ets.lookup(:proxy_epmd, node_key) == []
    end
  end

  defp generate_unrelated_key!(dir) do
    path = Path.join(dir, "unrelated_ed25519_#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"])
    File.chmod!(path, 0o600)
    path
  end
end
