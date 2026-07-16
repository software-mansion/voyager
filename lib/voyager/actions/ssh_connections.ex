defmodule Voyager.Actions.SshConnections do
  @moduledoc "Write actions for persisted SSH connection profiles."

  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.SshConnection

  @type upsert_opts :: [
          cookie: String.t() | nil,
          name_type: :shortnames | :longnames,
          auth_method: :agent | :password,
          password: String.t() | nil,
          epmd_port: integer()
        ]

  @type changeset_result :: {:ok, SshConnection.t()} | {:error, Ecto.Changeset.t()}
  @type mutation_result :: {:ok, SshConnection.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
   Creates or updates an SSH connection profile when a node is successfully
   connected.
  """
  @spec upsert_connected(String.t(), String.t(), integer(), String.t(), upsert_opts()) ::
          changeset_result()
  def upsert_connected(ssh_user, ssh_host, ssh_port, node_name, opts \\ []) do
    cookie = Keyword.get(opts, :cookie)
    password = Keyword.get(opts, :password)
    name_type = Keyword.get(opts, :name_type) || :longnames
    auth_method = Keyword.get(opts, :auth_method) || :agent
    epmd_port = Keyword.get(opts, :epmd_port) || 4369
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_conflict_set = [
      last_connected_at: now,
      updated_at: DateTime.to_naive(now),
      name_type: name_type,
      auth_method: auth_method,
      epmd_port: epmd_port
    ]

    on_conflict_set =
      if cookie, do: [{:cookie, cookie} | on_conflict_set], else: on_conflict_set

    on_conflict_set =
      if password, do: [{:password, password} | on_conflict_set], else: on_conflict_set

    %SshConnection{}
    |> SshConnection.changeset(%{
      ssh_user: ssh_user,
      ssh_host: ssh_host,
      ssh_port: ssh_port,
      node_name: node_name,
      cookie: cookie,
      name_type: name_type,
      auth_method: auth_method,
      password: password,
      epmd_port: epmd_port,
      last_connected_at: now
    })
    |> Repo.insert(
      on_conflict: [set: on_conflict_set],
      conflict_target: [:ssh_user, :ssh_host, :ssh_port, :node_name]
    )
  end

  @spec pin(integer()) :: mutation_result()
  def pin(id) do
    case SshConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> conn |> SshConnection.changeset(%{pinned: true}) |> Repo.update()
    end
  end

  @spec unpin(integer()) :: mutation_result()
  def unpin(id) do
    case SshConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> conn |> SshConnection.changeset(%{pinned: false}) |> Repo.update()
    end
  end

  @spec delete(integer()) :: mutation_result()
  def delete(id) do
    case SshConnectionQueries.get(id) do
      nil -> {:error, :not_found}
      conn -> Repo.delete(conn)
    end
  end
end
