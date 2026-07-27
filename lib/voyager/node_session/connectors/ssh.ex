defmodule Voyager.NodeSession.Connectors.Ssh do
  @moduledoc """
  SSH-tunnelled `Voyager.NodeSession.Connector` — distribution bridged through
  an SSH gateway via `Voyager.Services.RemoteNodeConnector`.
  """

  @behaviour Voyager.NodeSession.Connector

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector

  @impl true
  def name, do: :ssh

  @impl true
  def connect(node_name, cookie, opts) do
    with {:ok, ssh_user} <- fetch_required(opts, :ssh_user),
         {:ok, ssh_host} <- fetch_required(opts, :ssh_host) do
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
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
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
