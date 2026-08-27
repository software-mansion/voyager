defmodule Voyager.Services.Erlssh.Connection do
  @moduledoc """
  Low-level Erlang SSH primitives: connect, open a TCP tunnel to a remote port,
  and discover the Erlang distribution port by querying the remote `epmd` over
  the tunnel.
  """

  alias Voyager.Epmd.Client
  alias Voyager.Services.Erlssh.Auth

  require Auth

  @ssh_timeout 5000

  @spec connect_ssh(String.t(), :inet.port_number(), String.t(), Auth.auth()) ::
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

  @spec open_tunnel(:ssh.connection_ref(), integer(), integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def open_tunnel(conn_ref, remote_port, local_port \\ 0) do
    :ssh.tcpip_tunnel_to_server(conn_ref, ~c"127.0.0.1", local_port, ~c"127.0.0.1", remote_port)
  end

  @doc """
  Discovers the distribution port of `node_name` on the remote host.
  """
  @spec discover_dist_port(:ssh.connection_ref(), String.t(), integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def discover_dist_port(conn_ref, node_name, epmd_port \\ Voyager.Epmd.Daemon.port()) do
    with {:ok, epmd_local_port} <- open_tunnel(conn_ref, epmd_port),
         {:ok, output} <-
           Client.get_names(~c"127.0.0.1", epmd_local_port, @ssh_timeout) do
      parse_epmd_names(output, node_name)
    end
  end

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
end
