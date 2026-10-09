defmodule Voyager.Queries.Connections do
  @moduledoc "Read queries for persisted connection history."

  import Ecto.Query
  alias Voyager.Repo
  alias Voyager.Schemas.Connection

  @type optional :: Connection.t() | nil

  @spec all() :: [Connection.t()]
  def all do
    Connection
    |> order_by([c], desc: c.pinned, desc: c.last_connected_at)
    |> Repo.all()
  end

  @spec get(integer()) :: optional()
  def get(id), do: Repo.get(Connection, id)

  @spec get_by_node_name(String.t()) :: optional()
  def get_by_node_name(node_name), do: Repo.get_by(Connection, node_name: node_name)

  @doc "Returns the most recently connected node whose cookie is saved, so it can reconnect unattended."
  @spec last_connectable() :: optional()
  def last_connectable do
    Connection
    |> where([c], not is_nil(c.cookie))
    |> order_by([c], desc: c.last_connected_at)
    |> limit(1)
    |> Repo.one()
  end
end
