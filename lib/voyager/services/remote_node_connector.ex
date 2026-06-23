defmodule Voyager.Services.RemoteNodeConnector do
  @moduledoc """
  OpenSSH-binary based remote distribution tunnel.

  Two phases:

    1. **Discover** — `Voyager.Services.OpenSSH.Executor.exec/6` runs
       `epmd -names` on the remote box via `ssh user@host -- "epmd -names"`.
       The distribution port is parsed from the output.
    2. **Tunnel** — `Voyager.Services.OpenSSH.Tunnel` spawns a persistent
       `ssh -L local_port:node_host:dist_port -N` subprocess. The Tunnel
       GenServer pid is registered with `Voyager.ProxyEpmd.TunnelRegistry`
       so the BEAM's distribution layer routes through the forwarded port.

  The OpenSSH binary inherits the user's `~/.ssh/config` (including
  `ProxyJump`), agent forwarding from `SSH_AUTH_SOCK`, and the system's
  installed identities. Host keys are verified against
  `Voyager.Services.OpenSSH.KnownHosts` with `StrictHostKeyChecking=yes` —
  unknown hosts must be added first via the TOFU flow (see
  `Voyager.Services.OpenSSH.HostScanner`).

  The returned Tunnel pid is monitored by the caller — if the tunnel dies the
  caller receives a `{:DOWN, ref, :process, pid, reason}` message but is not
  killed. The caller is responsible for invoking `stop/2` (or letting its own
  `terminate/2` do it) to tear the tunnel down on its own shutdown.

  ## Usage

      {:ok, node, tunnel, ref, _port} =
        RemoteNodeConnector.connect("user", "remote.host", "myapp", :agent)

      :rpc.call(node, :erlang, :node, [])
      RemoteNodeConnector.stop(tunnel, ref)

  ## Options

    * `:ssh_port` — SSH port on the remote host. Defaults to `22`.
    * `:node_host` — hostname the remote node was started with. Defaults to
      `"127.0.0.1"`.
    * `:epmd_prefix` — list of shell tokens prepended to `epmd -names` on the
      remote (e.g. `["sudo", "-u", "app"]`). Treated as trusted input.

  ## Auth

    * `:agent` — delegates to the local ssh-agent (`SSH_AUTH_SOCK` must be set)
    * `{:key, path, nil}` — unencrypted private key file at `path`

  Encrypted keys and password authentication are not supported by this PR —
  load encrypted keys into `ssh-agent` and use `:agent` instead.
  """

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.OpenSSH.Executor
  alias Voyager.Services.OpenSSH.Tunnel
  alias Voyager.Services.OpenSSH.Validate

  @max_tunnel_attempts 3

  @type auth ::
          :agent
          | {:key, Path.t(), nil}

  @spec connect(String.t(), String.t(), String.t(), auth(), keyword()) ::
          {:ok, node(), pid(), reference(), pos_integer()} | {:error, term()}
  def connect(user, host, node_name, auth, opts \\ []) do
    ssh_port = Keyword.get(opts, :ssh_port, 22)
    node_host = Keyword.get(opts, :node_host, "127.0.0.1")

    with {:ok, node_name} <- Validate.node_name(node_name),
         {:ok, node_host} <- Validate.host(node_host),
         {:ok, remote_node} <- build_remote_node(node_name, node_host),
         {:ok, normalized_auth} <- normalize_auth(auth),
         {:ok, dist_port} <-
           discover_dist_port(user, host, ssh_port, normalized_auth, node_name, opts),
         {:ok, tunnel_pid, local_port} <-
           open_tunnel(user, host, ssh_port, normalized_auth, node_host, dist_port),
         node_key = String.to_charlist(node_name),
         :ok <- TunnelRegistry.register(node_key, local_port, tunnel_pid) do
      ref = Process.monitor(tunnel_pid)

      case Node.connect(remote_node) do
        true ->
          {:ok, remote_node, tunnel_pid, ref, local_port}

        false ->
          cleanup(tunnel_pid, ref, node_key)
          {:error, :node_connect_failed}

        :ignored ->
          cleanup(tunnel_pid, ref, node_key)
          {:error, :not_distributed}
      end
    end
  end

  @spec stop(pid(), reference() | nil) :: :ok
  def stop(tunnel_pid, ref \\ nil) when is_pid(tunnel_pid) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    Tunnel.stop(tunnel_pid)
  end

  @doc false
  @spec parse_port(binary(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def parse_port(output, node_name) when is_binary(output) do
    case Regex.run(
           ~r/^\s*name\s+#{Regex.escape(node_name)}\s+at\s+port\s+(\d+)\s*$/m,
           output
         ) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> {:error, {:node_not_found, node_name, output}}
    end
  end

  @doc false
  @spec discover_dist_port(
          String.t(),
          String.t(),
          pos_integer(),
          Executor.auth(),
          String.t(),
          keyword()
        ) ::
          {:ok, pos_integer()} | {:error, term()}
  def discover_dist_port(user, host, ssh_port, auth, node_name, opts \\ []) do
    with {:ok, output} <- Executor.exec(user, host, ssh_port, auth, "epmd -names", opts) do
      parse_port(output, node_name)
    end
  end

  defp build_remote_node(node_name, node_host) do
    label = "#{node_name}@#{node_host}"

    if byte_size(label) <= 255 do
      {:ok, String.to_atom(label)}
    else
      {:error, {:invalid_node_name, node_name}}
    end
  end

  defp normalize_auth(:agent), do: {:ok, :agent}
  defp normalize_auth({:key, path, nil}) when is_binary(path), do: {:ok, {:key, path}}
  defp normalize_auth(_), do: {:error, :auth_method_unsupported}

  defp open_tunnel(user, host, ssh_port, auth, node_host, dist_port, attempt \\ 1) do
    with {:ok, local_port} <- pick_port() do
      result =
        Tunnel.start_link(
          user: user,
          host: host,
          ssh_port: ssh_port,
          auth: auth,
          local_port: local_port,
          remote_host: node_host,
          remote_port: dist_port,
          owner: TunnelRegistry
        )

      case result do
        {:ok, pid} ->
          {:ok, pid, local_port}

        {:error, {:tunnel_not_ready, _, stderr}} = err ->
          maybe_retry_tunnel(err, stderr, {user, host, ssh_port, auth, node_host, dist_port}, attempt)

        {:error, _} = err ->
          err
      end
    end
  end

  defp maybe_retry_tunnel(err, stderr, {user, host, ssh_port, auth, node_host, dist_port}, attempt) do
    if port_collision?(stderr) and attempt < @max_tunnel_attempts do
      open_tunnel(user, host, ssh_port, auth, node_host, dist_port, attempt + 1)
    else
      err
    end
  end

  defp port_collision?(stderr) when is_binary(stderr) do
    String.contains?(stderr, "Address already in use") or
      String.contains?(stderr, "cannot listen to port")
  end

  defp port_collision?(_), do: false

  defp pick_port do
    case :gen_tcp.listen(0, active: false) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, _} = err ->
        err
    end
  end

  defp cleanup(tunnel_pid, ref, node_key) do
    Process.demonitor(ref, [:flush])
    TunnelRegistry.unregister(node_key)
    Tunnel.stop(tunnel_pid)
  end
end
