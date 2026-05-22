defmodule DockerNode do
  @moduledoc """
  Connect the local BEAM to a BEAM node running inside a Docker container.

  The container may live on the local machine or on a remote machine reachable
  over SSH. We never start or modify the container — we only `docker exec` into
  it (optionally via `ssh`) to:

    1. discover the BEAM distribution port via `epmd -names`
    2. shuttle TCP for the distribution connection through `docker exec -i ... nc`

  A small TCP listener is opened on the local machine; each accepted connection
  spawns a fresh `docker exec -i <container> nc 127.0.0.1 <dist_port>` whose
  stdio is bridged to the socket. The local port is registered in the shared
  `:proxy_epmd` ETS table so `ProxyEpmd` resolves the remote node's
  name+host to that port, and `Node.connect/1` goes through the shuttle.

  Requirements inside the container:
    * `epmd` on PATH (true for any Elixir/Erlang image)
    * `nc` on PATH — busybox `nc` is fine, so `elixir:*-alpine` works out of the box

  Usage

      iex -pa . \\
        --name local_node@127.0.0.1 \\
        --cookie mycookie \\
        --erl "-epmd_module Elixir.ProxyEpmd" \\
        -S mix

  Local container:

      DockerNode.connect("my_container", "app")

  Container on a remote host:

      DockerNode.connect("my_container", "app", ssh_user_host: "user@1.2.3.4")
  """

  @node_host "127.0.0.1"
  @proxy_epmd_table :proxy_epmd

  @doc """
  Discovers the in-container distribution port, starts a local TCP listener
  that bridges per-connection to `nc` inside the container, registers proxy
  data in `:proxy_epmd`, then calls `Node.connect/1`.

  Options:
    * `:ssh_user_host` — when set, the container is on a remote host and we
      wrap the docker invocation with `ssh <user_host>`
    * `:ssh` — extra args prepended to the `ssh` argv
    * `:local_port` — local listener port (default: ephemeral)
    * `:local_bind` — local listener bind address (default: `"127.0.0.1"`)
    * `:listener_ready_attempts` / `:listener_ready_interval_ms` — readiness poll

  Returns `{:ok, remote_node, listener_pid, local_port}` or `{:error, reason}`.
  """
  @spec connect(String.t(), String.t(), keyword()) ::
          {:ok, node(), pid(), pos_integer()} | {:error, term()}
  def connect(container, node_name, opts \\ []) do
    node_key = String.to_charlist(node_name)
    remote_node = String.to_atom("#{node_name}@#{@node_host}")

    with {:ok, dist_port} <- discover_port(container, node_name, opts),
         {:ok, listener_pid, local_port} <- start_listener(container, dist_port, opts),
         :ok <- ensure_proxy_epmd_table(),
         :ok <- register_proxy(node_key, local_port, listener_pid),
         :ok <- wait_for_listener(local_port, opts),
         true <- Node.connect(remote_node) do
      {:ok, remote_node, listener_pid, local_port}
    else
      false ->
        cleanup_proxy(node_key)
        {:error, :node_connect_failed}

      {:error, _} = error ->
        cleanup_proxy(node_key)
        error
    end
  end

  @doc "Stops the listener process started by `connect/3`."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
          :ok
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  defp discover_port(container, node_name, opts) do
    {cmd, args} = docker_exec_cmd(container, ["epmd", "-names"], opts)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        case find_port(output, node_name) do
          {:ok, port} -> {:ok, port}
          :error -> {:error, {:node_not_found, node_name, output}}
        end

      {output, code} ->
        {:error, {:docker_exec_failed, code, String.trim(output)}}
    end
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

  # Build `{executable, argv}` to run a command inside the target container,
  # optionally wrapped in `ssh user@host`.
  defp docker_exec_cmd(container, container_args, opts) do
    interactive? = Keyword.get(opts, :interactive, false)
    docker_flags = if interactive?, do: ["exec", "-i"], else: ["exec"]
    docker_args = docker_flags ++ [container | container_args]

    case Keyword.get(opts, :ssh_user_host) do
      nil ->
        {"docker", docker_args}

      user_host ->
        ssh_extra = Keyword.get(opts, :ssh, [])
        {"ssh", ssh_extra ++ [user_host, "docker" | docker_args]}
    end
  end

  # ---------------------------------------------------------------------------
  # Listener
  # ---------------------------------------------------------------------------

  defp start_listener(container, dist_port, opts) do
    local_port = Keyword.get(opts, :local_port, 0)
    local_bind = Keyword.get(opts, :local_bind, "127.0.0.1")

    with {:ok, bind_addr} <- :inet.parse_address(String.to_charlist(local_bind)),
         {:ok, lsock} <-
           :gen_tcp.listen(local_port, [
             :binary,
             {:ip, bind_addr},
             {:packet, :raw},
             {:active, false},
             {:reuseaddr, true}
           ]),
         {:ok, actual_port} <- :inet.port(lsock) do
      caller = self()

      pid =
        spawn_link(fn ->
          :gen_tcp.controlling_process(lsock, self())
          send(caller, {:listener_ready, self()})
          accept_loop(lsock, container, dist_port, opts)
        end)

      :gen_tcp.controlling_process(lsock, pid)

      receive do
        {:listener_ready, ^pid} -> {:ok, pid, actual_port}
      after
        5_000 -> {:error, :listener_start_timeout}
      end
    end
  end

  defp accept_loop(lsock, container, dist_port, opts) do
    receive do
      :stop ->
        :gen_tcp.close(lsock)
        :ok
    after
      0 ->
        case :gen_tcp.accept(lsock, 200) do
          {:ok, client} ->
            spawn_handler(client, container, dist_port, opts)
            accept_loop(lsock, container, dist_port, opts)

          {:error, :timeout} ->
            accept_loop(lsock, container, dist_port, opts)

          {:error, :closed} ->
            :ok

          {:error, _reason} ->
            accept_loop(lsock, container, dist_port, opts)
        end
    end
  end

  defp spawn_handler(client_sock, container, dist_port, opts) do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          {:assigned, ^parent, sock} -> handle_client(sock, container, dist_port, opts)
        after
          5_000 -> :ok
        end
      end)

    case :gen_tcp.controlling_process(client_sock, pid) do
      :ok -> send(pid, {:assigned, parent, client_sock})
      _ -> :gen_tcp.close(client_sock)
    end
  end

  defp handle_client(client_sock, container, dist_port, opts) do
    {cmd, args} =
      docker_exec_cmd(
        container,
        ["nc", "127.0.0.1", Integer.to_string(dist_port)],
        Keyword.put(opts, :interactive, true)
      )

    with {:ok, cmd_path} <- find_executable(cmd) do
      port =
        Port.open({:spawn_executable, cmd_path}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, args}
        ])

      case :inet.setopts(client_sock, active: true) do
        :ok ->
          shuttle(client_sock, port)

        {:error, _} ->
          if Port.info(port), do: Port.close(port)
          :gen_tcp.close(client_sock)
      end
    else
      _ -> :gen_tcp.close(client_sock)
    end
  end

  defp shuttle(client_sock, port) do
    receive do
      {:tcp, ^client_sock, data} ->
        Port.command(port, data)
        shuttle(client_sock, port)

      {:tcp_closed, ^client_sock} ->
        close_port(port)
        :ok

      {:tcp_error, ^client_sock, _reason} ->
        close_port(port)
        :gen_tcp.close(client_sock)

      {^port, {:data, data}} ->
        :gen_tcp.send(client_sock, data)
        shuttle(client_sock, port)

      {^port, {:exit_status, _status}} ->
        :gen_tcp.close(client_sock)
        :ok
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  defp wait_for_listener(local_port, opts) do
    bind = Keyword.get(opts, :local_bind, "127.0.0.1") |> String.to_charlist()
    attempts = Keyword.get(opts, :listener_ready_attempts, 50)
    interval = Keyword.get(opts, :listener_ready_interval_ms, 50)
    do_wait_for_listener(bind, local_port, attempts, interval)
  end

  defp do_wait_for_listener(_bind, _port, 0, _interval), do: {:error, :listener_not_ready}

  defp do_wait_for_listener(bind, port, attempts, interval) do
    case :gen_tcp.connect(bind, port, [:binary, active: false], interval) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(interval)
        do_wait_for_listener(bind, port, attempts - 1, interval)
    end
  end

  # ---------------------------------------------------------------------------
  # Proxy registration — shares the `:proxy_epmd` ETS table with RemoteNode/ProxyEpmd
  # ---------------------------------------------------------------------------

  defp ensure_proxy_epmd_table do
    case :ets.whereis(@proxy_epmd_table) do
      :undefined ->
        :ets.new(@proxy_epmd_table, [:set, :public, :named_table])
        :ok

      _ ->
        :ok
    end
  end

  defp register_proxy(node_key, local_port, listener_pid) do
    :ets.insert(@proxy_epmd_table, {
      node_key,
      %{port: local_port, address: {127, 0, 0, 1}, tunnel: listener_pid}
    })

    :ok
  end

  defp cleanup_proxy(node_key) do
    case :ets.whereis(@proxy_epmd_table) do
      :undefined ->
        :ok

      _ ->
        case :ets.lookup(@proxy_epmd_table, node_key) do
          [{^node_key, %{tunnel: pid}}] when is_pid(pid) -> stop(pid)
          _ -> :ok
        end

        :ets.delete(@proxy_epmd_table, node_key)
        :ok
    end
  end
end
