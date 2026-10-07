defmodule Voyager.Services.RemoteNodeConnector do
  @moduledoc """
  Connects to a remote Erlang node via SSH using `Voyager.Services.Ssh`.

  Ensures the local node is distributed, opens an SSH connection to the gateway
  host, discovers the target node's distribution port by querying the remote
  `epmd` over a TCP tunnel, opens a local TCP tunnel to
  that port, sets the remote node cookie, and calls `Node.connect/1`.

  ## Example

      # Using the local SSH agent
      {:ok, node, conn_ref, local_port} =
        RemoteNodeConnector.connect(
          "alice",
          "bastion.example.com",
          "myapp@10.0.0.5",
          "s3cret-cookie",
          :agent
        )

      # Using a password
      {:ok, node, conn_ref, local_port} =
        RemoteNodeConnector.connect(
          "alice",
          "bastion.example.com",
          "myapp@10.0.0.5",
          "s3cret-cookie",
          {:password, "s3cret"},
          ssh_port: 2222,
          epmd_port: 4369
        )

      # Disconnect
      RemoteNodeConnector.stop(conn_ref)

  ## Options

    * `:ssh_port` — SSH port on the gateway host. Defaults to `22`.
    * `:epmd_port` — TCP port the remote `epmd` listens on, queried over the SSH
      tunnel to discover the target node's distribution port. Defaults to `4369`.
    * `:name_type` — `:longnames` or `:shortnames`; how local distribution is
      started. Defaults to `:longnames`.
  """

  import Voyager.ProxyEpmd.Guard

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.Distribution
  alias Voyager.Services.Ssh
  alias Voyager.Validate

  require Ssh

  @epmd_names_req 110
  @epmd_timeout 5000

  @doc """
  Establishes an SSH connection and sets up a local TCP tunnel to the remote node.

  Use this function when you need to bridge local distribution to a remote node.

  ## Examples

      # Using the local SSH agent
      Voyager.Services.RemoteNodeConnector.connect("voyager", "1.2.3.4", "test@10.0.0.5", "cookie", :agent)
      #=> {:ok, :"test@10.0.0.5", conn_ref, 54321}

      # Using a password and custom options
      Voyager.Services.RemoteNodeConnector.connect("voyager", "1.2.3.4", "test@10.0.0.5", "cookie", {:password, "secret"}, ssh_port: 2222)
      #=> {:ok, :"test@10.0.0.5", conn_ref, 54322}
  """
  @spec connect(String.t(), String.t(), String.t(), String.t(), Ssh.auth(), keyword()) ::
          {:ok, remote_node :: node(), conn_ref :: Ssh.conn(), local_port :: pos_integer()}
          | {:error, reason :: term()}
  def connect(ssh_user, ssh_host, full_node_name, cookie, auth, opts \\ [])
      when Ssh.is_ssh_auth(auth) do
    require_epmd do
      epmd_port = Keyword.get(opts, :epmd_port, 4369)
      ssh_port = Keyword.get(opts, :ssh_port, 22)
      name_type = Keyword.get(opts, :name_type, :longnames)

      with :ok <- Validate.node_name(full_node_name),
           {:ok, node_name, node_host} <- Distribution.split_node_name(full_node_name),
           :ok <- Validate.host(node_host),
           :ok <- Validate.host(ssh_host),
           {:ok, conn_ref} <- Ssh.connect(ssh_host, ssh_port, ssh_user, auth) do
        establish(conn_ref, full_node_name, node_name, node_host, name_type, cookie, epmd_port)
      end
    end
  end

  @spec stop(Ssh.conn()) :: :ok
  def stop(conn_ref) when is_pid(conn_ref) do
    require_epmd do
      TunnelRegistry.unregister_by_tunnel(conn_ref)
      Ssh.close(conn_ref)
    end
  end

  defp establish(conn_ref, full_node_name, node_name, node_host, name_type, cookie, epmd_port) do
    node_key = String.to_charlist(node_name)
    remote_node = String.to_atom(full_node_name)

    remote_hosts = Enum.uniq(["127.0.0.1", node_host])

    with :ok <- Distribution.ensure_distributed(name_type),
         {:ok, local_port} <-
           connect_through(remote_hosts, conn_ref, node_name, remote_node, cookie, epmd_port) do
      {:ok, remote_node, conn_ref, local_port}
    else
      {:error, _} = err ->
        Ssh.close(conn_ref)
        TunnelRegistry.unregister(node_key)
        err
    end
  end

  defp connect_through(remote_hosts, conn_ref, node_name, remote_node, cookie, epmd_port) do
    Enum.reduce_while(remote_hosts, nil, fn remote_host, first_error ->
      case connect_via(remote_host, conn_ref, node_name, remote_node, cookie, epmd_port) do
        {:ok, _local_port} = ok -> {:halt, ok}
        error -> {:cont, first_error || error}
      end
    end)
  end

  defp connect_via(remote_host, conn_ref, node_name, remote_node, cookie, epmd_port) do
    node_key = String.to_charlist(node_name)

    with {:ok, dist_port} <- discover_dist_port(conn_ref, remote_host, node_name, epmd_port),
         {:ok, local_port} <- Ssh.open_tunnel(conn_ref, remote_host, dist_port),
         :ok <- TunnelRegistry.register(node_key, local_port, conn_ref) do
      case connect_node(remote_node, cookie) do
        true -> {:ok, local_port}
        false -> {:error, :node_connect_failed}
        :ignored -> {:error, :not_distributed}
      end
    end
  end

  defp connect_node(remote_node, cookie) do
    :erlang.set_cookie(remote_node, String.to_atom(cookie))
    result = Node.connect(remote_node)
    :erlang.set_cookie(remote_node, :nocookie)
    result
  end

  defp discover_dist_port(conn_ref, remote_host, node_name, epmd_port) do
    with {:ok, epmd_local_port} <- Ssh.open_tunnel(conn_ref, remote_host, epmd_port),
         {:ok, output} <- query_epmd_names(epmd_local_port) do
      parse_epmd_names(output, node_name)
    end
  end

  defp query_epmd_names(local_port) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", local_port, opts, @epmd_timeout) do
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
    case :gen_tcp.recv(sock, 0, @epmd_timeout) do
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
end
