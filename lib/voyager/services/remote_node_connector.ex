defmodule Voyager.Services.RemoteNodeConnector do
  @moduledoc """
  Connects to a remote Erlang node via SSH using Erlang's built-in `:ssh`.

  Opens an SSH connection to the gateway host, discovers the target node's
  distribution port via `epmd -names`, opens a local TCP tunnel to that port,
  and calls `Node.connect/1`.

  ## Example

      # Using the local SSH agent
      {:ok, node, conn_ref, ref, local_port} =
        RemoteNodeConnector.connect("alice", "bastion.example.com", "myapp@10.0.0.5", :agent)

      # Using a password
      {:ok, node, conn_ref, ref, local_port} =
        RemoteNodeConnector.connect(
          "alice",
          "bastion.example.com",
          "myapp@10.0.0.5",
          {:password, "s3cret"},
          ssh_port: 2222,
          epmd_prefix: "/opt/homebrew/bin"
        )

      # Disconnect
      RemoteNodeConnector.stop(conn_ref, ref)

  ## Options

    * `:ssh_port` — SSH port on the gateway host. Defaults to `22`.
    * `:epmd_prefix` — absolute path to the directory holding the remote `epmd`
      binary, for hosts where it is not on the non-interactive SSH `PATH`
      (e.g. `/opt/homebrew/bin`). Validated by `Voyager.Validate.epmd_prefix/1`.
  """

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.Erlssh.Auth
  alias Voyager.Services.Erlssh.Connection
  alias Voyager.Validate

  @spec connect(String.t(), String.t(), String.t(), Auth.auth(), keyword()) ::
          {:ok, node(), pid(), reference(), pos_integer()} | {:error, term()}
  def connect(ssh_user, ssh_host, full_node_name, auth, opts \\ []) do
    epmd_prefix = Keyword.get(opts, :epmd_prefix, "")
    ssh_port = Keyword.get(opts, :ssh_port, 22)

    with :ok <- Validate.node_name(full_node_name),
         {:ok, node_name, node_host} <- split_node_name(full_node_name),
         :ok <- Validate.host(node_host),
         :ok <- Validate.epmd_prefix(epmd_prefix),
         {:ok, conn_ref} <- Connection.connect_ssh(ssh_host, ssh_port, ssh_user, auth) do
      establish(conn_ref, full_node_name, node_name, epmd_prefix)
    end
  end

  @spec stop(pid(), reference() | nil) :: :ok
  def stop(conn_ref, ref \\ nil) when is_pid(conn_ref) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    :ssh.close(conn_ref)
  end

  @spec split_node_name(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, {:invalid_node_format, String.t()}}
  def split_node_name(full_node_name) when is_binary(full_node_name) do
    case String.split(full_node_name, "@", parts: 2) do
      [name, host] -> {:ok, name, host}
      _ -> {:error, {:invalid_node_format, full_node_name}}
    end
  end

  defp establish(conn_ref, full_node_name, node_name, epmd_prefix) do
    node_key = String.to_charlist(node_name)

    with {:ok, dist_port} <- Connection.discover_dist_port(conn_ref, node_name, epmd_prefix),
         {:ok, local_port} <- Connection.open_tunnel(conn_ref, dist_port),
         :ok <- TunnelRegistry.register(node_key, local_port, conn_ref) do
      ref = Process.monitor(conn_ref)
      remote_node = String.to_atom(full_node_name)

      case Node.connect(remote_node) do
        true ->
          {:ok, remote_node, conn_ref, ref, local_port}

        false ->
          cleanup(conn_ref, ref, node_key)
          {:error, :node_connect_failed}

        :ignored ->
          cleanup(conn_ref, ref, node_key)
          {:error, :not_distributed}
      end
    else
      {:error, _} = err ->
        :ssh.close(conn_ref)
        TunnelRegistry.unregister(node_key)
        err
    end
  end

  defp cleanup(conn_ref, ref, node_key) do
    Process.demonitor(ref, [:flush])
    :ssh.close(conn_ref)
    TunnelRegistry.unregister(node_key)
  end
end
