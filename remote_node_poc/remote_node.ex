defmodule RemoteNode do
  @moduledoc """
  Two-phase remote Erlang setup over SSH:

  1. **Discover** — one-shot `ssh` runs `epmd -names`, parse the distribution port, session ends.
  2. **Tunnel** — long-lived `ssh -N -L` forwards the remote distribution port to localhost.

  Close the returned tunnel `Port` (or call `stop_tunnel/1`) to tear down forwarding.
  """

  @node_host "127.0.0.1"
  @proxy_epmd_table :proxy_epmd

  @doc """
  Discovers the remote distribution port, starts an SSH tunnel, registers proxy
  data in `:proxy_epmd` for `ProxyEpmd`, then calls `Node.connect/1`.

  Returns `{:ok, remote_node, tunnel, local_port}` or `{:error, reason}`.
  """
  @spec connect(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, node(), port(), pos_integer()} | {:error, term()}
  def connect(user, host, node_name, opts \\ []) do
    user_host = "#{user}@#{host}"
    node_key = String.to_charlist(node_name)
    remote_node = String.to_atom("#{node_name}@#{@node_host}")

    with {:ok, dist_port} <- discover_port(user_host, node_name, opts),
         {:ok, tunnel, local_port} <- start_tunnel(user_host, dist_port, opts),
         :ok <- ensure_proxy_epmd_table(),
         :ok <- register_proxy(node_key, local_port, tunnel),
         :ok <- wait_for_tunnel(local_port, opts),
         true <- Node.connect(remote_node) do
      {:ok, remote_node, tunnel, local_port}
    else
      false ->
        cleanup_proxy(node_key)
        {:error, :node_connect_failed}

      {:error, _} = error ->
        cleanup_proxy(node_key)
        error
    end
  end

  @doc "Closes the tunnel `Port` opened by `start_tunnel/3`."
  @spec stop_tunnel(port()) :: :ok
  def stop_tunnel(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp wait_for_tunnel(local_port, opts) do
    bind = Keyword.get(opts, :local_bind, "127.0.0.1") |> String.to_charlist()
    attempts = Keyword.get(opts, :tunnel_ready_attempts, 50)
    interval = Keyword.get(opts, :tunnel_ready_interval_ms, 100)
    do_wait_for_tunnel(bind, local_port, attempts, interval)
  end

  defp do_wait_for_tunnel(_bind, _port, 0, _interval), do: {:error, :tunnel_not_ready}

  defp do_wait_for_tunnel(bind, port, attempts, interval) do
    case :gen_tcp.connect(bind, port, [:binary, active: false], interval) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(interval)
        do_wait_for_tunnel(bind, port, attempts - 1, interval)
    end
  end

  defp discover_port(user_host, node_name, opts) do
    remote_prefix = Keyword.get(opts, :remote_prefix, [])
    epmd_args = remote_prefix ++ ["epmd", "-names"]
    ssh_args = Keyword.get(opts, :ssh, []) ++ [user_host | epmd_args]

    case System.cmd("ssh", ssh_args, stderr_to_stdout: true) do
      {output, 0} ->
        case find_port(output, node_name) do
          {:ok, port} -> {:ok, port}
          :error -> {:error, {:node_not_found, node_name, output}}
        end

      {output, code} ->
        {:error, {:ssh_failed, code, String.trim(output)}}
    end
  end

  defp start_tunnel(user_host, dist_port, opts) do
    local_port = Keyword.get(opts, :local_port, dist_port)
    local_bind = Keyword.get(opts, :local_bind, "127.0.0.1")
    remote_host = Keyword.get(opts, :remote_host, "127.0.0.1")
    ssh_extra = Keyword.get(opts, :ssh, [])

    forwards = [
      "-L",
      "#{local_bind}:#{local_port}:#{remote_host}:#{dist_port}"
    ]

    ssh_args =
      ssh_extra ++
        [
          "-N",
          "-o",
          "ExitOnForwardFailure=yes",
          "-o",
          "ServerAliveInterval=60"
        ] ++ forwards ++ [user_host]

    with {:ok, ssh} <- find_executable("ssh"),
         {:ok, sh} <- find_executable("sh") do
      port =
        Port.open({:spawn_executable, sh}, [
          :binary,
          :exit_status,
          args: ["-c", tunnel_watchdog_script(), "tunnel_watchdog", ssh | ssh_args]
        ])

      {:ok, port, local_port}
    end
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  # Wrapper script that ties the SSH child's lifetime to BEAM's:
  #
  #   * SSH is started in its own process group (`setsid` if available, else
  #     plain background) so we can signal the whole tree.
  #   * The script then blocks reading stdin. BEAM holds the write end of that
  #     pipe; the pipe closes when BEAM exits for *any* reason — clean exit,
  #     SIGKILL, segfault, OOM. EOF on `read` unblocks the loop and we kill SSH.
  #   * Traps cover the clean-shutdown path (Port.close on this side).
  defp tunnel_watchdog_script do
    """
    ssh_bin="$1"; shift
    "$ssh_bin" "$@" &
    child=$!
    cleanup() { kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; }
    trap 'cleanup; exit' EXIT TERM INT HUP
    while IFS= read -r _line; do :; done
    cleanup
    """
  end

  defp find_port(output, node_name) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case Regex.named_captures(~r/^name (?<name>\S+) at port (?<port>\d+)$/, line) do
        %{"name" => ^node_name, "port" => port} -> {:ok, String.to_integer(port)}
        _ -> false
      end
    end)
  end

  defp ensure_proxy_epmd_table do
    case :ets.whereis(@proxy_epmd_table) do
      :undefined ->
        :ets.new(@proxy_epmd_table, [:set, :public, :named_table])
        :ok

      _ ->
        :ok
    end
  end

  defp register_proxy(node_key, local_port, tunnel) do
    :ets.insert(@proxy_epmd_table, {
      node_key,
      %{port: local_port, address: {127, 0, 0, 1}, tunnel: tunnel}
    })

    :ok
  end

  defp cleanup_proxy(node_key) do
    case :ets.whereis(@proxy_epmd_table) do
      :undefined ->
        :ok

      _ ->
        case :ets.lookup(@proxy_epmd_table, node_key) do
          [{^node_key, %{tunnel: tunnel}}] -> stop_tunnel(tunnel)
          _ -> :ok
        end

        :ets.delete(@proxy_epmd_table, node_key)
        :ok
    end
  end
end
