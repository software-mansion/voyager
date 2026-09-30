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
end
