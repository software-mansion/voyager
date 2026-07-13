defmodule Voyager.NodeSession.Connectors.Ssh do
  @moduledoc """
  SSH-tunnelled `Voyager.NodeSession.Connector` — distribution bridged through
  an SSH gateway via `Voyager.Services.RemoteNodeConnector`.

  Subscribes the session to `TunnelRegistry`'s topic so a dying tunnel is
  reported as a teardown even when the remote node itself stays up. This module
  is the only main-tree reference to the SSH connector: deleting the SSH feature
  means deleting this file and dropping the `connect_via/4` caller.
  """

  @behaviour Voyager.NodeSession.Connector

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector

  @impl true
  def name, do: :ssh

  @impl true
  def connect(node_name, cookie, opts) do
    ssh_user = Keyword.fetch!(opts, :ssh_user)
    ssh_host = Keyword.fetch!(opts, :ssh_host)
    auth = Keyword.get(opts, :auth, :agent)
    rc_opts = Keyword.take(opts, [:ssh_port, :epmd_port, :name_type])

    case RemoteNodeConnector.connect(ssh_user, ssh_host, node_name, cookie, auth, rc_opts) do
      {:ok, node, conn_ref, local_port} ->
        meta = %{
          conn_ref: conn_ref,
          local_port: local_port,
          ssh_user: ssh_user,
          ssh_host: ssh_host
        }

        {:ok, node, meta}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def disconnect(_node, %{conn_ref: conn_ref}), do: RemoteNodeConnector.stop(conn_ref)

  @impl true
  def subscriptions, do: [TunnelRegistry.topic()]

  @impl true
  def teardown?({:tunnel_down, conn_ref}, %{conn_ref: conn_ref}), do: true
  def teardown?(_msg, _meta), do: false
end
