defmodule Voyager.Schemas.SshConnection do
  @moduledoc """
  Ecto schema for a persisted SSH tunnel connection profile.

  Stores the SSH gateway credentials, the remote node name, and optionally
  encrypted cookie and SSH password. Unique per `(ssh_user, ssh_host, ssh_port,
  node_name)` — the same node reachable through different gateways produces
  separate rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: pos_integer() | nil,
          ssh_user: String.t() | nil,
          ssh_host: String.t() | nil,
          ssh_port: integer(),
          node_name: String.t() | nil,
          cookie: String.t() | nil,
          name_type: :shortnames | :longnames,
          auth_method: :agent | :password,
          password: String.t() | nil,
          epmd_port: integer(),
          pinned: boolean(),
          last_connected_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "ssh_connections" do
    field :ssh_user, :string
    field :ssh_host, :string
    field :ssh_port, :integer, default: 22
    field :node_name, :string
    field :cookie, Voyager.Encrypted.Binary
    field :name_type, Ecto.Enum, values: [:shortnames, :longnames], default: :longnames
    field :auth_method, Ecto.Enum, values: [:agent, :password], default: :agent
    field :password, Voyager.Encrypted.Binary
    field :epmd_port, :integer, default: 4369
    field :pinned, :boolean, default: false
    field :last_connected_at, :utc_datetime

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ssh_connection, attrs) do
    ssh_connection
    |> cast(attrs, [
      :ssh_user,
      :ssh_host,
      :ssh_port,
      :node_name,
      :cookie,
      :name_type,
      :auth_method,
      :password,
      :epmd_port,
      :pinned,
      :last_connected_at
    ])
    |> validate_required([
      :ssh_user,
      :ssh_host,
      :ssh_port,
      :node_name,
      :name_type,
      :auth_method,
      :epmd_port,
      :last_connected_at
    ])
    |> validate_length(:ssh_user, max: 255)
    |> validate_length(:ssh_host, max: 255)
    |> validate_length(:node_name, max: 255)
    |> unique_constraint([:ssh_user, :ssh_host, :ssh_port, :node_name])
  end
end
