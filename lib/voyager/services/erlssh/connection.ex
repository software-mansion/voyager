defmodule Voyager.Services.Erlssh.Connection do
  @moduledoc """
  Low-level Erlang SSH primitives: connect, open a TCP tunnel to a remote port,
  and discover the Erlang distribution port by querying the remote `epmd` over
  the tunnel.
  """

  alias Voyager.Services.Erlssh.Auth

  require Auth

  @ssh_timeout 5000
  @epmd_names_req 110
  @epmd_port 4369

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

  Opens a short-lived TCP tunnel to the remote `epmd`, sends an EPMD `NAMES` request, and parses the reply.
  Performs blocking SSH and TCP operations and can block the caller for up to
  #{@ssh_timeout}ms; run it inside a `Task` or supervised process.
  """
  @spec discover_dist_port(:ssh.connection_ref(), String.t(), integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def discover_dist_port(conn_ref, node_name, epmd_port \\ @epmd_port) do
    with {:ok, epmd_local_port} <- open_tunnel(conn_ref, epmd_port),
         {:ok, output} <- query_epmd_names(epmd_local_port) do
      parse_epmd_names(output, node_name)
    end
  end

  defp query_epmd_names(local_port) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", local_port, opts, @ssh_timeout) do
      result = send_epmd_request(sock)
      :gen_tcp.close(sock)
      result
    end
  end

  defp send_epmd_request(sock) do
    with :ok <- :gen_tcp.send(sock, <<1::16, @epmd_names_req>>),
         {:ok, resp} <- recv_until_closed(sock, <<>>) do
      parse_names_response(resp)
    end
  end

  # First 4 bytes are epmd's own port; the rest is the "name ... at port N" text.
  defp parse_names_response(<<_epmd_port::32, text::binary>>), do: {:ok, text}
  defp parse_names_response(_), do: {:error, :invalid_epmd_response}

  defp recv_until_closed(sock, acc) do
    case :gen_tcp.recv(sock, 0, @ssh_timeout) do
      {:ok, data} -> recv_until_closed(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, _} = err -> err
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
