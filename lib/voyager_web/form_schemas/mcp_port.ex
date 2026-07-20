defmodule VoyagerWeb.FormSchemas.McpPort do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :port, :integer
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:port])
    |> validate_required([:port])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
  end
end
