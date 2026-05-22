defmodule Voyager.Queries.Connections do
  @moduledoc "Read queries for persisted connection history."

  import Ecto.Query
  alias Voyager.Schemas.Connection
  alias Voyager.Repo

  @type optional :: Connection.t() | nil

  @spec all() :: [Connection.t()]
  def all() do
    Connection
    |> order_by([c], desc: c.pinned, desc: c.last_connected_at)
    |> Repo.all()
  end

  @spec get(integer()) :: optional()
  def get(id), do: Repo.get(Connection, id)

  @spec get_by_node_name(String.t()) :: optional()
  def get_by_node_name(node_name), do: Repo.get_by(Connection, node_name: node_name)
end
