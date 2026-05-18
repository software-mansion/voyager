defmodule Voyager.Connections.Connection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "connections" do
    field :node_name, :string
    field :cookie, :string
    field :label, :string
    field :pinned, :boolean, default: false
    field :last_connected_at, :utc_datetime
    field :connected_count, :integer, default: 1

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:node_name, :cookie, :label, :pinned, :last_connected_at, :connected_count])
    |> validate_required([:node_name, :last_connected_at])
    |> unique_constraint(:node_name)
  end
end
