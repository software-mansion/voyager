defmodule VoyagerWeb.FormSchemas.TraceStorageParams do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :limit_mb, :integer
  end

  @type t :: %__MODULE__{}

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:limit_mb])
    |> validate_required([:limit_mb])
    |> validate_number(:limit_mb, greater_than: 0, less_than: 1_000_000_000_000_000)
  end
end
