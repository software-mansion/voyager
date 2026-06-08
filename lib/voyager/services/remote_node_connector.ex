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
  The SSH connection ref is linked to the caller, so killing your IEx shell
  tears the tunnel down. Call `stop/1` for clean shutdown.
  Pair with `Voyager.ProxyEpmd` set at boot via `-epmd_module`:
      iex -pa . --name local@127.0.0.1 --cookie mycookie \\
        --erl "-epmd_module Elixir.Voyager.ProxyEpmd" -S mix
  Usage:
      {:ok, node, conn, port} =
        Voyager.Services.RemoteNodeConnector.connect("user", "127.0.0.1", "app", {:password, "secret"})
      Node.list()
      :rpc.call(node, :erlang, :node, [])
      Voyager.Services.RemoteNodeConnector.stop(conn)
  """

  @proxy_table :proxy_epmd
  @local_bind ~c"127.0.0.1"
  @remote_dist_host ~c"127.0.0.1"

  @type auth ::
          :agent
          | {:password, String.t()}
          | {:key, Path.t(), String.t() | nil}

  @spec connect(String.t(), String.t(), String.t(), auth(), keyword()) ::
          {:ok, node(), pid(), pos_integer()} | {:error, term()}
  def connect(user, host, node_name, auth, opts \\ []) do
    ssh_port = Keyword.get(opts, :ssh_port, 22)
    node_key = String.to_charlist(node_name)
    remote_node = String.to_atom("#{node_name}@127.0.0.1")

    with :ok <- ensure_ssh_started(),
         :ok <- ensure_proxy_table(),
         {:ok, conn} <- ssh_connect(host, ssh_port, user, auth) do
      Process.link(conn)

      with {:ok, dist_port} <- discover_dist_port(conn, node_name, opts),
           {:ok, local_port} <-
             :ssh.tcpip_tunnel_to_server(
               conn,
               @local_bind,
               0,
               @remote_dist_host,
               dist_port,
               5_000
             ),
           :ok <- register_proxy(node_key, local_port, conn),
           true <- Node.connect(remote_node) do
        {:ok, remote_node, conn, local_port}
      else
        false ->
          cleanup(conn, node_key)
          {:error, :node_connect_failed}

        {:error, _} = err ->
          cleanup(conn, node_key)
          err
      end
    end
  end

  @spec stop(pid()) :: :ok
  def stop(conn) when is_pid(conn) do
    :ssh.close(conn)
  end

  defp cleanup(conn, node_key) do
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

  defp discover_dist_port(conn, node_name, opts) do
    prefix = opts |> Keyword.get(:remote_prefix, []) |> Enum.join(" ")
    cmd = if prefix == "", do: "epmd -names\n", else: "#{prefix} epmd -names\n"

    with {:ok, ch} <- :ssh_connection.session_channel(conn, 5_000),
         :success <- :ssh_connection.exec(conn, ch, String.to_charlist(cmd), 5_000) do
      output = collect_exec_output(conn, ch, [])
      parse_port(output, node_name)
    else
      :failure -> {:error, :exec_failure}
      {:error, _} = err -> err
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
        IO.iodata_to_binary(Enum.reverse(acc))
    after
      5_000 -> ""
    end
  end

  defp parse_port(output, node_name) when is_binary(output) do
    case Regex.run(~r/^name #{Regex.escape(node_name)} at port (\d+)$/m, output) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> {:error, {:node_not_found, node_name, output}}
    end
  end

  defp ensure_proxy_table do
    case :ets.whereis(@proxy_table) do
      :undefined ->
        :ets.new(@proxy_table, [:set, :public, :named_table])
        :ok

      _ ->
        :ok
    end
  end

  defp register_proxy(node_key, local_port, conn) do
    :ets.insert(@proxy_table, {
      node_key,
      %{port: local_port, address: {127, 0, 0, 1}, tunnel: conn}
    })

    :ok
  end

  defp cleanup_proxy(node_key) do
    case :ets.whereis(@proxy_table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete(@proxy_table, node_key)
        :ok
    end
  end
end
