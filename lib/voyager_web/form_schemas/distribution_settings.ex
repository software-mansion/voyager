defmodule VoyagerWeb.FormSchemas.DistributionSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :distribution_suffix, :string, default: ""
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:distribution_suffix], empty_values: [])
    |> validate_required([:distribution_suffix])
    |> validate_format(:distribution_suffix, ~r/^[A-Za-z0-9_-]*$/,
      message: "Use only letters, numbers, underscores, or hyphens"
    )
    |> validate_length(:distribution_suffix, max: 64)
  end
end
