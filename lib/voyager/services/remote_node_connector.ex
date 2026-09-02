defmodule Voyager.Services.RemoteNodeConnector do
  @moduledoc """
  Connects to a remote Erlang node via SSH using Erlang's built-in `:ssh`.

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
  alias Voyager.Services.Erlssh.Auth
  alias Voyager.Services.Erlssh.Connection
  alias Voyager.Validate

  require Auth

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
  @spec connect(String.t(), String.t(), String.t(), String.t(), Auth.auth(), keyword()) ::
          {:ok, remote_node :: node(), conn_ref :: :ssh.connection_ref(),
           local_port :: pos_integer()}
          | {:error, reason :: term()}
  def connect(ssh_user, ssh_host, full_node_name, cookie, auth, opts \\ [])
      when Auth.is_ssh_auth(auth) do
    require_epmd do
      epmd_port = Keyword.get(opts, :epmd_port, 4369)
      ssh_port = Keyword.get(opts, :ssh_port, 22)
      name_type = Keyword.get(opts, :name_type, :longnames)

      with :ok <- Validate.node_name(full_node_name),
           {:ok, node_name, node_host} <- Distribution.split_node_name(full_node_name),
           :ok <- Validate.host(node_host),
           :ok <- Validate.host(ssh_host),
           {:ok, conn_ref} <- Connection.connect_ssh(ssh_host, ssh_port, ssh_user, auth) do
        establish(conn_ref, full_node_name, node_name, name_type, cookie, epmd_port)
      end
    end
  end

  @spec stop(:ssh.connection_ref()) :: :ok
  def stop(conn_ref) when is_pid(conn_ref) do
    require_epmd do
      TunnelRegistry.unregister_by_tunnel(conn_ref)
      :ssh.close(conn_ref)
    end
  end

  defp establish(conn_ref, full_node_name, node_name, name_type, cookie, epmd_port) do
    node_key = String.to_charlist(node_name)

    with :ok <- Distribution.ensure_distributed(name_type),
         {:ok, dist_port} <- Connection.discover_dist_port(conn_ref, node_name, epmd_port),
         {:ok, local_port} <- Connection.open_tunnel(conn_ref, dist_port),
         :ok <- TunnelRegistry.register(node_key, local_port, conn_ref) do
      remote_node = String.to_atom(full_node_name)

      :erlang.set_cookie(remote_node, String.to_atom(cookie))
      connect_result = Node.connect(remote_node)
      :erlang.set_cookie(remote_node, :nocookie)

      case connect_result do
        true ->
          {:ok, remote_node, conn_ref, local_port}

        false ->
          cleanup(conn_ref, node_key)
          {:error, :node_connect_failed}

        :ignored ->
          cleanup(conn_ref, node_key)
          {:error, :not_distributed}
      end
    else
      {:error, _} = err ->
        :ssh.close(conn_ref)
        TunnelRegistry.unregister(node_key)
        err
    end
  end

  defp cleanup(conn_ref, node_key) do
    :ssh.close(conn_ref)
    TunnelRegistry.unregister(node_key)
  end
end
