defmodule Voyager.Schemas.Connection do
  @moduledoc """
  Ecto schema for a persisted node connection.

  Stores the node name, an optionally encrypted cookie, pin status, and the
  last time Voyager successfully connected.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: pos_integer() | nil,
          node_name: String.t() | nil,
          cookie: String.t() | nil,
          name_type: :shortnames | :longnames,
          pinned: boolean(),
          last_connected_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "connections" do
    field :node_name, :string
    field :cookie, Voyager.Encrypted.Binary
    field :name_type, Ecto.Enum, values: [:shortnames, :longnames], default: :longnames
    field :pinned, :boolean, default: false
    field :last_connected_at, :utc_datetime

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:node_name, :cookie, :name_type, :pinned, :last_connected_at])
    |> validate_required([:node_name, :last_connected_at])
    |> validate_length(:node_name, max: 255)
    |> validate_length(:cookie, max: 255)
    |> unique_constraint(:node_name)
  end
end
