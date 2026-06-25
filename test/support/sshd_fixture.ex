defmodule Voyager.SshdFixture do
  @moduledoc """
  Boots a real OpenSSH `sshd` on a random port for integration tests.

  The daemon is configured to:

    * accept pubkey authentication for the current OS user using a generated
      ed25519 client key (returned in the context),
    * answer every exec channel with a shell wrapper that prints a canned
      `epmd -names` style payload — sufficient to drive
      `Voyager.Services.Erlssh.Connection.discover_dist_port/3` end-to-end
      without a real Erlang node on the remote side,
    * permit TCP port forwarding so tunnel integration tests can exercise
      `:ssh.tcpip_tunnel_to_server/6` against the same daemon.

  Use `start!/0` in `setup`/`setup_all`. The returned context exposes the
  paths and port needed by the `:ssh` client modules.
  """

  @epmd_output """
  epmd: up and running on port 4369 with data:
  name myapp at port 41234
  name other at port 99
  """

  @type ctx :: %{
          port: pos_integer(),
          user: String.t(),
          host: String.t(),
          key_path: String.t(),
          host_key_path: String.t(),
          dir: String.t(),
          sshd_port: port()
        }

  @spec start!() :: ctx()
  def start! do
    sshd = System.find_executable("sshd") || raise "sshd not found in PATH"
    user = System.get_env("USER") || raise "USER env var must be set"

    dir = make_dir!()

    host_key = generate_host_key!(dir)
    {client_key, client_pub} = generate_client_key!(dir)
    authorized_keys = write_authorized_keys!(dir, client_pub)
    wrapper = write_force_command_wrapper!(dir)
    config = write_config!(dir, host_key, authorized_keys, wrapper, user)

    port = free_port()
    sshd_port = open_sshd_port(sshd, config, port)

    case wait_for_tcp(port, 5_000) do
      :ok ->
        %{
          port: port,
          user: user,
          host: "127.0.0.1",
          key_path: client_key,
          host_key_path: host_key,
          dir: dir,
          sshd_port: sshd_port
        }

      {:error, reason} ->
        stderr = drain_port(sshd_port, "")
        if Port.info(sshd_port) != nil, do: Port.close(sshd_port)
        File.rm_rf!(dir)
        raise "sshd failed to start (#{inspect(reason)}): #{stderr}"
    end
  end

  @spec stop!(ctx()) :: :ok
  def stop!(%{sshd_port: sshd_port, dir: dir}) do
    if Port.info(sshd_port) != nil, do: Port.close(sshd_port)
    File.rm_rf!(dir)
    :ok
  end

  @doc """
  Pre-populates the Voyager known_hosts file with the fixture's host key so
  client connections succeed with `StrictHostKeyChecking=yes`.

  Returns the configured known_hosts path so the caller can override and
  restore the `:voyager, :known_hosts_path` application env around the test.
  """
  @spec install_host_key!(ctx()) :: String.t()
  def install_host_key!(%{port: port, host_key_path: host_key_path}) do
    kh_dir = Path.join(System.tmp_dir!(), "voyager_kh_fix_#{System.unique_integer([:positive])}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")

    pub = File.read!(host_key_path <> ".pub") |> String.trim()
    entry = "[127.0.0.1]:#{port} #{pub}\n"
    File.write!(kh_path, entry)

    kh_path
  end

  defp make_dir! do
    dir = Path.join(System.tmp_dir!(), "voyager_sshd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp generate_host_key!(dir) do
    path = Path.join(dir, "ssh_host_ed25519_key")
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"])
    File.chmod!(path, 0o600)
    path
  end

  defp generate_client_key!(dir) do
    path = Path.join(dir, "client_ed25519")
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"])
    File.chmod!(path, 0o600)
    pub = File.read!(path <> ".pub")
    {path, pub}
  end

  defp write_authorized_keys!(dir, pub) do
    path = Path.join(dir, "authorized_keys")
    File.write!(path, pub)
    File.chmod!(path, 0o600)
    path
  end

  defp write_force_command_wrapper!(dir) do
    path = Path.join(dir, "force_command.sh")

    script = """
    #!/bin/sh
    case "$SSH_ORIGINAL_COMMAND" in
      *"epmd -names"*)
        cat <<'EOF'
    #{String.trim_trailing(@epmd_output)}
    EOF
        ;;
      *)
        echo "unknown command: $SSH_ORIGINAL_COMMAND" >&2
        exit 1
        ;;
    esac
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp write_config!(dir, host_key, authorized_keys, wrapper, user) do
    path = Path.join(dir, "sshd_config")

    cfg = """
    HostKey #{host_key}
    PidFile #{dir}/sshd.pid
    UsePAM no
    StrictModes no
    PasswordAuthentication no
    ChallengeResponseAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile #{authorized_keys}
    AllowUsers #{user}
    AllowTcpForwarding yes
    PermitOpen any
    LogLevel ERROR
    ForceCommand #{wrapper}
    Subsystem sftp internal-sftp
    """

    File.write!(path, cfg)
    File.chmod!(path, 0o600)
    path
  end

  defp open_sshd_port(sshd, config, port) do
    Port.open(
      {:spawn_executable, to_charlist(sshd)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-D", "-e", "-p", "#{port}", "-f", config]
      ]
    )
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, active: false)
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    p
  end

  defp wait_for_tcp(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_tcp(port, deadline)
  end

  defp do_wait_tcp(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 200) do
      {:ok, s} ->
        :gen_tcp.close(s)
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_wait_tcp(port, deadline)
        end
    end
  end

  defp drain_port(port, acc) do
    receive do
      {^port, {:data, data}} -> drain_port(port, acc <> data)
    after
      100 -> acc
    end
  end
end
