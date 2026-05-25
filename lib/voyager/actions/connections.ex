defmodule Voyager.Actions.Connections do
  @moduledoc "Write actions for persisted connection history."

  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.Connection

  @type upsert_opts :: [cookie: String.t() | nil]
  @type changeset_result :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  @type mutation_result ::
          {:ok, Connection.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
  Creates or updates a connection record when a node is successfully connected.

  Always updates `last_connected_at`. When `:cookie` is supplied in `opts`, the
  stored cookie is overwritten; when omitted, any existing cookie is preserved.
  """
  @spec upsert_connected(String.t(), upsert_opts()) :: changeset_result()
  def upsert_connected(node_name, opts \\ []) do
    cookie = Keyword.get(opts, :cookie)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_conflict =
      if cookie do
        [set: [last_connected_at: now, cookie: cookie]]
      else
        [set: [last_connected_at: now]]
      end

    %Connection{}
    |> Connection.changeset(%{node_name: node_name, cookie: cookie, last_connected_at: now})
    |> Repo.insert(on_conflict: on_conflict, conflict_target: :node_name)
  end

  @spec pin(integer()) :: mutation_result()
  def pin(id) do
    case ConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> conn |> Connection.changeset(%{pinned: true}) |> Repo.update()
    end
  end

  @spec unpin(integer()) :: mutation_result()
  def unpin(id) do
    case ConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> conn |> Connection.changeset(%{pinned: false}) |> Repo.update()
    end
  end

  @spec delete(integer()) :: mutation_result()
  def delete(id) do
    case ConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> Repo.delete(conn)
    end
  end
end
