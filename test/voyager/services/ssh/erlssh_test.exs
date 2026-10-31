defmodule Voyager.Services.SSH.ErlsshTest do
  # async: false because the test points HOME, which is read for the system known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.Erlssh
  alias Voyager.Test.SshKeys
  alias Voyager.Test.SshServer

  @moduletag :tmp_dir

  @loopback {127, 0, 0, 1}
  @passphrase "test-passphrase"

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    known_hosts = Path.join([tmp_dir, "voyager", "known_hosts"])
    Application.put_env(:voyager, :known_hosts_path, known_hosts)

    on_exit(fn ->
      System.put_env("HOME", home)
      Application.delete_env(:voyager, :known_hosts_path)
    end)

    %{known_hosts: known_hosts, system_known_hosts: Path.join([tmp_dir, ".ssh", "known_hosts"])}
  end

  describe "keepalive" do
    setup do
      Application.put_env(:voyager, :ssh_alive, %{interval: 100, count_max: 2})
      on_exit(fn -> Application.delete_env(:voyager, :ssh_alive) end)
    end

    test "closes the connection when the server stops answering" do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)
      {:ok, conn} = connect(port, host_key: fingerprint)
      assert_receive {:ssh_server_connection, server_pid}
      ref = Process.monitor(conn)

      :sys.suspend(server_pid)
      assert_receive {:DOWN, ^ref, :process, ^conn, _reason}, 1_000
      :sys.resume(server_pid)
    end

    test "keeps an idle connection open while the server answers" do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)
      {:ok, conn} = connect(port, host_key: fingerprint)
      ref = Process.monitor(conn)

      refute_receive {:DOWN, ^ref, :process, ^conn, _reason}, 500
      Erlssh.close(conn)
    end
  end

  describe "host key verification" do
    test "returns the fingerprint of an unknown host key", ctx do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)

      assert {:error, {:unknown_host_key, ^fingerprint}} = connect(port)
      refute File.exists?(ctx.known_hosts)
    end

    test "pins an accepted key in Voyager's known_hosts only", ctx do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)

      assert {:ok, conn} = connect(port, host_key: fingerprint)
      Erlssh.close(conn)

      assert File.read!(ctx.known_hosts) =~ "[127.0.0.1]:#{port} ssh-ed25519 "
      refute File.exists?(ctx.system_known_hosts)
      assert {:ok, conn} = connect(port)
      Erlssh.close(conn)
    end

    test "rejects a fingerprint other than the accepted one", ctx do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)

      assert {:error, {:unknown_host_key, ^fingerprint}} = connect(port, host_key: "SHA256:x")
      refute File.exists?(ctx.known_hosts)
    end

    test "trusts a key from the system known_hosts", ctx do
      %{port: port, host_key: host_key} = SshServer.start!(@loopback)
      write_known_host!(ctx.system_known_hosts, "[127.0.0.1]:#{port}", host_key)

      assert {:ok, conn} = connect(port)
      Erlssh.close(conn)
    end

    test "fails when the host key changed", ctx do
      %{port: port} = SshServer.start!(@loopback)

      other_key =
        :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()

      write_known_host!(ctx.known_hosts, "[127.0.0.1]:#{port}", other_key)

      known_hosts = ctx.known_hosts
      assert {:error, {:host_key_mismatch, ^known_hosts}} = connect(port)
    end

    test "pins and checks the host name connected to, not its IP", ctx do
      %{port: port, fingerprint: fingerprint} = SshServer.start!(@loopback)

      assert {:ok, conn} = connect("localhost", port, host_key: fingerprint)
      Erlssh.close(conn)

      pinned = File.read!(ctx.known_hosts)
      assert pinned =~ "[localhost]:#{port} ssh-ed25519 "
      refute pinned =~ "127.0.0.1"
      assert {:ok, conn} = connect("localhost", port, [])
      Erlssh.close(conn)
    end
  end

  describe "key file auth" do
    test "logs in with an OpenSSH key", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])
      server = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(server, path, nil)
      Erlssh.close(conn)
    end

    test "logs in with an RSA key", %{tmp_dir: dir} do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      {path, public_key} = SshKeys.pem!(dir, "id_rsa", key)
      server = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(server, path, nil)
      Erlssh.close(conn)
    end

    test "logs in with an encrypted PEM key and its passphrase", %{tmp_dir: dir} do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {path, public_key} = SshKeys.pem!(dir, "id_ecdsa", key, @passphrase)
      server = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(server, path, @passphrase)
      Erlssh.close(conn)
    end

    test "fails with a key the server does not accept", %{tmp_dir: dir} do
      {path, _public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])
      server = SshServer.start!(@loopback)

      assert {:error, _reason} = connect_with_key(server, path, nil)
    end
  end

  describe "agent auth" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      {path, public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])
      server = SshServer.start!(@loopback, authorized_keys: [public_key])
      %{server: server, socket: start_agent!(path)}
    end

    test "logs in through a custom agent socket", %{server: server, socket: socket} do
      assert {:ok, conn} = connect_with_agent(server, socket)
      Erlssh.close(conn)
    end

    test "falls back to SSH_AUTH_SOCK without a socket path", %{server: server, socket: socket} do
      previous = System.get_env("SSH_AUTH_SOCK")
      System.put_env("SSH_AUTH_SOCK", socket)

      on_exit(fn ->
        if previous,
          do: System.put_env("SSH_AUTH_SOCK", previous),
          else: System.delete_env("SSH_AUTH_SOCK")
      end)

      assert {:ok, conn} = connect_with_agent(server, nil)
      Erlssh.close(conn)
    end

    test "fails when nothing listens on the agent socket", %{server: server, tmp_dir: dir} do
      assert {:error, _reason} = connect_with_agent(server, Path.join(dir, "missing.sock"))
    end
  end

  defp connect(port, opts \\ []), do: connect("127.0.0.1", port, opts)

  defp connect(host, port, opts),
    do: Erlssh.connect(host, port, SshServer.user(), {:password, SshServer.password()}, opts)

  defp connect_with_key(server, path, passphrase),
    do:
      Erlssh.connect("127.0.0.1", server.port, SshServer.user(), {:key, path, passphrase},
        host_key: server.fingerprint
      )

  defp connect_with_agent(server, socket),
    do:
      Erlssh.connect("127.0.0.1", server.port, SshServer.user(), {:agent, socket},
        host_key: server.fingerprint
      )

  defp write_known_host!(path, host, key) do
    line = :ssh_file.encode([{key, [hostnames: [String.to_charlist(host)]]}], :known_hosts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, line)
  end

  # tmp_dir paths overflow the 104-byte Unix socket path limit on macOS.
  defp start_agent!(key_path) do
    socket = Path.join(System.tmp_dir!(), "voyager-#{System.unique_integer([:positive])}.sock")
    {output, 0} = System.cmd("ssh-agent", ["-a", socket])
    [_, pid] = Regex.run(~r/SSH_AGENT_PID=(\d+)/, output)
    on_exit(fn -> System.cmd("kill", [pid]) end)

    {_, 0} =
      System.cmd("ssh-add", [key_path], env: [{"SSH_AUTH_SOCK", socket}], stderr_to_stdout: true)

    socket
  end
end
