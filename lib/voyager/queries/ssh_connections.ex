defmodule Voyager.Queries.SshConnections do
  @moduledoc "Read queries for persisted SSH connection profiles."

  import Ecto.Query
  alias Voyager.Repo
  alias Voyager.Schemas.SshConnection

  @spec all() :: [SshConnection.t()]
  def all do
    SshConnection
    |> order_by([c], desc: c.pinned, desc: c.last_connected_at)
    |> Repo.all()
  end

  @spec get(integer()) :: SshConnection.t() | nil
  def get(id), do: Repo.get(SshConnection, id)

  @spec get_by_profile(String.t(), String.t(), integer(), String.t()) ::
          SshConnection.t() | nil
  def get_by_profile(ssh_user, ssh_host, ssh_port, node_name) do
    Repo.get_by(SshConnection,
      ssh_user: ssh_user,
      ssh_host: ssh_host,
      ssh_port: ssh_port,
      node_name: node_name
    )
  end

  @doc "Returns the most recently connected profile with every credential saved, so it can reconnect unattended."
  @spec last_connectable() :: SshConnection.t() | nil
  def last_connectable do
    SshConnection
    |> where([c], not is_nil(c.cookie))
    |> where([c], c.auth_method == :agent or not is_nil(c.password))
    |> order_by([c], desc: c.last_connected_at)
    |> limit(1)
    |> Repo.one()
  end
end
