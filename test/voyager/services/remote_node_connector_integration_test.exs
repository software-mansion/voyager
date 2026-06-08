defmodule Voyager.Services.RemoteNodeConnectorIntegrationTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.RemoteNodeConnector

  @moduletag :ssh_integration
  @moduletag capture_log: true

  @epmd_output "epmd: up and running on port 4369 with data:\nname myapp at port 41234\nname other at port 99\n"

  setup_all do
    :ok = ensure_ssh_started()
    :ok
  end

  setup do
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
  end

  describe "discover_dist_port/3 against a real SSH daemon" do
    test "parses the port for a node present in epmd output", %{port: port} do
      {:ok, conn} = open_client(port, "test", "password")

      assert {:ok, 41_234} = RemoteNodeConnector.discover_dist_port(conn, "myapp")

      :ssh.close(conn)
    end

    test "returns :node_not_found when the node is absent", %{port: port} do
      {:ok, conn} = open_client(port, "test", "password")

      assert {:error, {:node_not_found, "missing", _output}} =
               RemoteNodeConnector.discover_dist_port(conn, "missing")

      :ssh.close(conn)
    end

    test "honors :epmd_prefix without losing the node match", %{port: port} do
      {:ok, conn} = open_client(port, "test", "password")

      assert {:ok, 41_234} =
               RemoteNodeConnector.discover_dist_port(conn, "myapp", epmd_prefix: ["env"])

      :ssh.close(conn)
    end
  end

  describe "auth failure modes" do
    test "wrong password is rejected", %{port: port} do
      assert {:error, _} = open_client(port, "test", "wrong")
    end

    test "unknown user is rejected", %{port: port} do
      assert {:error, _} = open_client(port, "other", "password")
    end
  end

  defp ensure_ssh_started do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp open_client(port, user, pass) do
    :ssh.connect(
      ~c"127.0.0.1",
      port,
      [
        user: String.to_charlist(user),
        password: String.to_charlist(pass),
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
    cmd_str = List.to_string(cmd)

    if String.contains?(cmd_str, "epmd -names") do
      {:ok, @epmd_output}
    else
      {:ok, "unknown command: " <> cmd_str <> "\n"}
    end
  end

  defp make_system_dir! do
    dir = Path.join(System.tmp_dir!(), "voyager_ssh_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
    pem = :public_key.pem_encode([pem_entry])

    File.write!(Path.join(dir, "ssh_host_rsa_key"), pem)

    dir
  end
end
