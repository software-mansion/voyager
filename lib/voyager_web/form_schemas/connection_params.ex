defmodule VoyagerWeb.FormSchemas.ConnectionParams do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :node_name, :string
    field :cookie, :string
    field :name_type, Ecto.Enum, values: [:shortnames, :longnames], default: :longnames
    field :remember_cookie, :boolean, default: false
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:node_name, :cookie, :name_type, :remember_cookie])
    |> validate_required([:node_name, :cookie])
    |> validate_format(:node_name, ~r/^[^@\s]+@[^@\s]+$/, message: "Use the name@host format")
    |> validate_length(:node_name, max: 255)
    |> validate_length(:cookie, max: 255)
  end
end
