defmodule Voyager.Services.Erlssh.Connection do
  @moduledoc """
  Low-level Erlang SSH primitives: connect, discover the Erlang distribution
  port via `epmd -names`, and open a TCP tunnel to the remote node.
  """

  alias Voyager.Services.Erlssh.Auth

  require Auth

  @ssh_timeout 5000

  @spec connect_ssh(String.t(), integer(), String.t(), Auth.auth()) ::
          {:ok, conn_ref :: :ssh.connection_ref()} | {:error, reason :: term()}
  def connect_ssh(host, ssh_port, ssh_user, auth \\ :agent) when Auth.is_ssh_auth(auth) do
    char_host = String.to_charlist(host)
    char_user = String.to_charlist(ssh_user)

    base_opts = [
      user: char_user,
      user_interaction: false,
      silently_accept_hosts: true,
      connect_timeout: @ssh_timeout
    ]

    :ssh.connect(char_host, ssh_port, base_opts ++ auth_opts(auth))
  end

  @doc """
  This function performs blocking SSH operations and can block the calling
  process for up to #{@ssh_timeout}ms. Run it inside a `Task` or supervised
  process to avoid blocking a caller.
  """
  @spec discover_dist_port(:ssh.connection_ref(), String.t(), String.t()) ::
          {:ok, integer()} | {:error, term()}
  def discover_dist_port(conn_ref, node_name, epmd_prefix \\ "") do
    epmd_command = build_epmd_command(epmd_prefix)

    case :ssh_connection.session_channel(conn_ref, @ssh_timeout) do
      {:ok, channel_id} ->
        exec_and_parse(conn_ref, channel_id, epmd_command, node_name)

      error ->
        {:error, {:ssh_failed, error}}
    end
  end

  @spec open_tunnel(:ssh.connection_ref(), integer(), integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def open_tunnel(conn_ref, remote_port, local_port \\ 0) do
    :ssh.tcpip_tunnel_to_server(conn_ref, ~c"127.0.0.1", local_port, ~c"127.0.0.1", remote_port)
  end

  @spec parse_epmd_names(binary(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_epmd_names(output, node_name) do
    case Regex.run(
           ~r/^\s*name\s+#{Regex.escape(node_name)}\s+at\s+port\s+(\d+)\s*$/m,
           output
         ) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> {:error, {:node_not_found, node_name, output}}
    end
  end

  defp auth_opts(:agent), do: []
  defp auth_opts({:password, pass}), do: [password: String.to_charlist(pass)]

  defp exec_and_parse(conn_ref, channel_id, epmd_command, node_name) do
    command_charlist = String.to_charlist(epmd_command)

    case :ssh_connection.exec(conn_ref, channel_id, command_charlist, @ssh_timeout) do
      :success ->
        output = collect_ssh_output(conn_ref, channel_id, "")
        parse_epmd_names(output, node_name)

      error ->
        :ssh_connection.close(conn_ref, channel_id)
        {:error, {:ssh_failed, error}}
    end
  end

  defp build_epmd_command(""), do: "epmd -names"

  defp build_epmd_command(prefix) do
    if String.contains?(prefix, "=") do
      "#{prefix} epmd -names"
    else
      "PATH=\"#{prefix}:$PATH\" epmd -names"
    end
  end

  defp collect_ssh_output(conn_ref, channel_id, acc) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel_id, 0, data}} ->
        collect_ssh_output(conn_ref, channel_id, acc <> to_string(data))

      {:ssh_cm, ^conn_ref, {:eof, ^channel_id}} ->
        collect_ssh_output(conn_ref, channel_id, acc)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel_id, _status}} ->
        # SSH sends: data -> eof -> exit_status -> closed; keep looping to consume {:closed}
        collect_ssh_output(conn_ref, channel_id, acc)

      {:ssh_cm, ^conn_ref, {:closed, ^channel_id}} ->
        acc
    after
      @ssh_timeout ->
        :ssh_connection.close(conn_ref, channel_id)
        acc
    end
  end
end
