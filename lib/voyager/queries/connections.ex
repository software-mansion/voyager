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
end
