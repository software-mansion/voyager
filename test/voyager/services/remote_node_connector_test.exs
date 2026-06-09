defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: false

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector

  @moduletag capture_log: true

  @epmd_output "epmd: up and running on port 4369 with data:\nname myapp at port 41234\nname other at port 99\n"

  setup_all do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup context do
    if context[:daemon] do
      system_dir = make_system_dir!()
      on_exit(fn -> File.rm_rf!(system_dir) end)

      {:ok, daemon} =
        :ssh.daemon(
          0,
          system_dir: String.to_charlist(system_dir),
          auth_methods: ~c"password",
          pwdfun: &password_check/2,
          exec: {:direct, &fake_epmd_exec/1}
        )

      {:ok, info} = :ssh.daemon_info(daemon)
      port = Keyword.fetch!(info, :port)
      on_exit(fn -> :ssh.stop_daemon(daemon) end)

      {:ok, port: port}
    else
      :ok
    end
  end

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
          {:password, "x"},
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end
  end

  describe "discover_dist_port/3" do
    @describetag :daemon
    test "parses the port for a node present in epmd output", %{port: port} do
      {:ok, conn} = open_client(port)
      assert {:ok, 41_234} = RemoteNodeConnector.discover_dist_port(conn, "myapp")
      :ssh.close(conn)
    end

    test "returns :node_not_found when the node is absent", %{port: port} do
      {:ok, conn} = open_client(port)

      assert {:error, {:node_not_found, "missing", _output}} =
               RemoteNodeConnector.discover_dist_port(conn, "missing")

      :ssh.close(conn)
    end

    test "honors :epmd_prefix without losing the node match", %{port: port} do
      {:ok, conn} = open_client(port)

      assert {:ok, 41_234} =
               RemoteNodeConnector.discover_dist_port(conn, "myapp", epmd_prefix: ["env"])

      :ssh.close(conn)
    end
  end

  describe "auth" do
    @describetag :daemon
    test "wrong password is rejected", %{port: port} do
      assert {:error, _} = open_client(port, "wrong")
    end

    test "unknown user is rejected", %{port: port} do
      assert {:error, _} =
               :ssh.connect(
                 ~c"127.0.0.1",
                 port,
                 [
                   user: ~c"other",
                   password: ~c"password",
                   silently_accept_hosts: true,
                   user_interaction: false,
                   auth_methods: ~c"password"
                 ],
                 5_000
               )
    end
  end

  describe "stop/2" do
    @describetag :daemon
    test "conn exit removes the ETS entry via TunnelRegistry", %{port: port} do
      {:ok, conn} = open_client(port)
      node_key = ~c"stoptest_#{System.unique_integer([:positive])}"
      TunnelRegistry.register(node_key, 12_345, conn)

      assert [{^node_key, _}] = :ets.lookup(:proxy_epmd, node_key)

      wait_ref = Process.monitor(conn)
      RemoteNodeConnector.stop(conn)

      assert_receive {:DOWN, ^wait_ref, :process, ^conn, _}
      _ = :sys.get_state(TunnelRegistry)

      assert :ets.lookup(:proxy_epmd, node_key) == []
    end

    test "demonitors the caller ref so no DOWN is delivered after stop", %{port: port} do
      {:ok, conn} = open_client(port)
      ref = Process.monitor(conn)

      RemoteNodeConnector.stop(conn, ref)

      refute_receive {:DOWN, ^ref, :process, ^conn, _}
    end
  end

  defp open_client(port, password \\ "password") do
    :ssh.connect(
      ~c"127.0.0.1",
      port,
      [
        user: ~c"test",
        password: String.to_charlist(password),
        silently_accept_hosts: true,
        user_interaction: false,
        auth_methods: ~c"password"
      ],
      5_000
    )
  end

  defp password_check(~c"test", ~c"password"), do: true
  defp password_check(_, _), do: false

  defp fake_epmd_exec(cmd) when is_list(cmd) do
    if String.contains?(List.to_string(cmd), "epmd -names") do
      {:ok, @epmd_output}
    else
      {:ok, "unknown command\n"}
    end
  end

  defp make_system_dir! do
    dir = Path.join(System.tmp_dir!(), "voyager_ssh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
    File.write!(Path.join(dir, "ssh_host_rsa_key"), :public_key.pem_encode([pem_entry]))

    dir
  end
end
