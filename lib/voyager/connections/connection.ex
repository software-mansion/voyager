defmodule Voyager.Connections.Connection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "connections" do
    field :node_name, :string
    field :cookie, :string
    field :pinned, :boolean, default: false
    field :last_connected_at, :utc_datetime

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:node_name, :cookie, :pinned, :last_connected_at])
    |> validate_required([:node_name, :last_connected_at])
    |> validate_length(:node_name, max: 255)
    |> validate_length(:cookie, max: 255)
    |> unique_constraint(:node_name)
  end
end
