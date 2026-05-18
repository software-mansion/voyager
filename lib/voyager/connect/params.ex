defmodule Voyager.Connect.Params do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :node_name, :string
    field :cookie, :string
    field :name_type, Ecto.Enum, values: [:shortnames, :longnames], default: :shortnames
    field :remember_cookie, :boolean, default: false
  end

  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:node_name, :cookie, :name_type, :remember_cookie])
    |> validate_required([:node_name, :cookie])
    |> validate_format(:node_name, ~r/^[^@\s]+@[^@\s]+$/, message: "Use the name@host format")
  end
end
