defmodule Voyager.Services.RemoteNodeConnector do
  @moduledoc """
  Erlang `:ssh`-based remote distribution tunnel — no subprocess, no shell.

  Two phases:

    1. **Discover** — `:ssh.connect/4` opens a connection. An exec channel runs
       `epmd -names` on the remote box and the distribution port is parsed
       from the output.
    2. **Tunnel** — `:ssh.tcpip_tunnel_to_server/6` binds a local port that
       forwards each accepted TCP connection through the existing SSH session
       to the remote node's distribution port. Equivalent to `ssh -L`, but
       multiplexed onto the same SSH connection (no second handshake).

  The returned SSH conn pid is monitored by the caller — if the tunnel dies
  the caller receives a `{:DOWN, ref, :process, conn, reason}` message but is
  not killed. The caller is responsible for invoking `stop/2` (or letting its
  own `terminate/2` do it) to tear the tunnel down on its own shutdown.

  Requires `Voyager.ProxyEpmd` to be active as the BEAM's `-epmd_module` so
  the distribution layer routes through the local tunnel port. See
  `Voyager.ProxyEpmd` for setup instructions.

  ## Usage

      {:ok, node, conn, ref, _port} =
        Voyager.Services.RemoteNodeConnector.connect("user", "remote.host", "myapp", :agent)

      Node.list()
      :rpc.call(node, :erlang, :node, [])
      Voyager.Services.RemoteNodeConnector.stop(conn, ref)

  ## Options

    * `:ssh_port` — SSH port on the remote host. Defaults to `22`.
    * `:node_host` — hostname the remote node was started with (the `@host` part
      of its name). Also used as the tunnel's forwarding target on the SSH
      server's side. Defaults to `"127.0.0.1"`. Override when the node was
      started with `--name app@actual.host` or runs on a different internal host
      reachable from the SSH server.
    * `:epmd_prefix` — list of shell tokens prepended to `epmd -names` on the
      remote (e.g. `["sudo", "-u", "app"]` or `["PATH=/usr/lib/erlang/bin:$PATH"]`).
      Treated as trusted input — do not pass user-controlled values.

  ## Auth

    * `:agent` — delegates to the local ssh-agent (`SSH_AUTH_SOCK` must be set)
    * `{:password, pw}` — password authentication
    * `{:key, path, passphrase | nil}` — private key file; `path` is the key
      file, its parent directory is used as the OTP ssh `user_dir`
  """

  alias Voyager.ProxyEpmd.TunnelRegistry

  @local_bind ~c"127.0.0.1"

  @type auth ::
          :agent
          | {:password, String.t()}
          | {:key, Path.t(), String.t() | nil}

  @spec connect(String.t(), String.t(), String.t(), auth(), keyword()) ::
          {:ok, node(), pid(), reference(), pos_integer()} | {:error, term()}
  def connect(user, host, node_name, auth, opts \\ []) do
    ssh_port = Keyword.get(opts, :ssh_port, 22)
    node_host = Keyword.get(opts, :node_host, "127.0.0.1")
    node_key = String.to_charlist(node_name)
    remote_node = String.to_atom("#{node_name}@#{node_host}")

    with :ok <- ensure_ssh_started(),
         {:ok, conn} <- ssh_connect(host, ssh_port, user, auth) do
      ref = Process.monitor(conn)

      with {:ok, dist_port} <- discover_dist_port(conn, node_name, opts),
           {:ok, local_port} <-
             :ssh.tcpip_tunnel_to_server(
               conn,
               @local_bind,
               0,
               String.to_charlist(node_host),
               dist_port,
               5_000
             ),
           :ok <- register_proxy(node_key, local_port, conn),
           true <- Node.connect(remote_node) do
        {:ok, remote_node, conn, ref, local_port}
      else
        false ->
          cleanup(conn, ref, node_key)
          {:error, :node_connect_failed}

        :ignored ->
          cleanup(conn, ref, node_key)
          {:error, :not_distributed}

        {:error, _} = err ->
          cleanup(conn, ref, node_key)
          err
      end
    end
  end

  @spec stop(pid(), reference() | nil) :: :ok
  def stop(conn, ref \\ nil) when is_pid(conn) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    :ssh.close(conn)
  end

  @doc false
  @spec parse_port(binary(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def parse_port(output, node_name) when is_binary(output) do
    case Regex.run(~r/^\s*name\s+#{Regex.escape(node_name)}\s+at\s+port\s+(\d+)\s*$/m, output) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> {:error, {:node_not_found, node_name, output}}
    end
  end

  defp cleanup(conn, ref, node_key) do
    Process.demonitor(ref, [:flush])
    cleanup_proxy(node_key)
    :ssh.close(conn)
  end

  defp ensure_ssh_started do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end

  defp ssh_connect(host, port, user, auth) do
    base = [
      user: String.to_charlist(user),
      silently_accept_hosts: true,
      user_interaction: false
    ]

    :ssh.connect(String.to_charlist(host), port, base ++ auth_opts(auth), 10_000)
  end

  defp auth_opts(:agent), do: []

  defp auth_opts({:password, pw}),
    do: [password: String.to_charlist(pw)]

  defp auth_opts({:key, path, nil}),
    do: [user_dir: String.to_charlist(Path.expand(Path.dirname(path)))]

  defp auth_opts({:key, path, passphrase}) do
    pp = String.to_charlist(passphrase)

    [
      user_dir: String.to_charlist(Path.expand(Path.dirname(path))),
      rsa_pass_phrase: pp,
      dsa_pass_phrase: pp,
      ecdsa_pass_phrase: pp,
      ed25519_pass_phrase: pp
    ]
  end

  @doc false
  @spec discover_dist_port(pid(), String.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def discover_dist_port(conn, node_name, opts \\ []) do
    prefix = opts |> Keyword.get(:epmd_prefix, []) |> Enum.join(" ")
    cmd = if prefix == "", do: "epmd -names\n", else: "#{prefix} epmd -names\n"

    with {:ok, ch} <- :ssh_connection.session_channel(conn, 5_000) do
      try do
        with :success <- :ssh_connection.exec(conn, ch, String.to_charlist(cmd), 5_000),
             {:ok, output} <- collect_exec_output(conn, ch, []) do
          parse_port(output, node_name)
        else
          :failure -> {:error, :exec_failure}
          :timeout -> {:error, :exec_timeout}
          {:error, _} = err -> err
        end
      after
        _ = :ssh_connection.close(conn, ch)
      end
    end
  end

  defp collect_exec_output(conn, ch, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, 0, data}} ->
        collect_exec_output(conn, ch, [data | acc])

      {:ssh_cm, ^conn, {:data, ^ch, 1, _stderr}} ->
        collect_exec_output(conn, ch, acc)

      {:ssh_cm, ^conn, {:eof, ^ch}} ->
        collect_exec_output(conn, ch, acc)

      {:ssh_cm, ^conn, {:exit_status, ^ch, _}} ->
        collect_exec_output(conn, ch, acc)

      {:ssh_cm, ^conn, {:closed, ^ch}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
    after
      5_000 -> :timeout
    end
  end

  defp register_proxy(node_key, local_port, conn) do
    TunnelRegistry.register(node_key, local_port, conn)
  end

  defp cleanup_proxy(node_key) do
    TunnelRegistry.unregister(node_key)
  end
end
