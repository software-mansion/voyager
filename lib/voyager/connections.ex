defmodule Voyager.Connections do
  @moduledoc "Context for persisted connection history."

  import Ecto.Query
  alias Voyager.Connections.Connection
  alias Voyager.Repo

  @doc "Returns all connections: pinned first, then most recently used."
  def list_connections do
    Connection
    |> order_by([c], desc: c.pinned, desc: c.last_connected_at)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(Connection, id)

  def get_by_node_name(node_name), do: Repo.get_by(Connection, node_name: node_name)

  @doc """
  Creates or updates a connection record when a node is successfully connected.
  """
  def upsert_connected(node_name, opts \\ []) do
    cookie = Keyword.get(opts, :cookie)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_conflict =
      if cookie,
        do: [set: [last_connected_at: now, cookie: cookie], inc: [connected_count: 1]],
        else: [set: [last_connected_at: now], inc: [connected_count: 1]]

    %Connection{}
    |> Connection.changeset(%{node_name: node_name, cookie: cookie, last_connected_at: now})
    |> Repo.insert(on_conflict: on_conflict, conflict_target: :node_name)
  end

  def pin(id, label \\ nil) do
    case Repo.get(Connection, id) do
      nil -> {:error, :not_found}
      conn -> conn |> Connection.changeset(%{pinned: true, label: label}) |> Repo.update()
    end
  end

  def unpin(id) do
    case Repo.get(Connection, id) do
      nil -> {:error, :not_found}
      conn -> conn |> Connection.changeset(%{pinned: false, label: nil}) |> Repo.update()
    end
  end

  def delete(id) do
    case Repo.get(Connection, id) do
      nil -> {:error, :not_found}
      conn -> Repo.delete(conn)
    end
  end
end
