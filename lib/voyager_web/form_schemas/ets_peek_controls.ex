defmodule VoyagerWeb.FormSchemas.EtsPeekControls do
  @moduledoc """
  Controls form for the ETS contents peek: how many records one chunk holds and
  how long to wait for it.

  `chunk_size` is validated against `Voyager.Services.Ets.Fetch`'s own chunk
  sizes rather than a free integer, because anything else is `:invalid_limit`
  at the API and `badarg` on the agent.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @chunk_sizes [10, 20, 50]
  @default_chunk_size 10
  @min_timeout 1_000
  @max_timeout 30_000
  @default_timeout 5_000

  @primary_key false
  embedded_schema do
    field :chunk_size, :integer, default: @default_chunk_size
    field :timeout, :integer, default: @default_timeout
  end

  @type t :: %__MODULE__{}

  @spec chunk_size_options() :: [pos_integer()]
  def chunk_size_options, do: @chunk_sizes

  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(controls \\ default(), attrs \\ %{}) do
    controls
    |> cast(attrs, [:chunk_size, :timeout])
    |> validate_required([:chunk_size, :timeout])
    |> validate_inclusion(:chunk_size, @chunk_sizes,
      message: "must be one of #{Enum.join(@chunk_sizes, ", ")}"
    )
    |> validate_number(:timeout,
      greater_than_or_equal_to: @min_timeout,
      less_than_or_equal_to: @max_timeout,
      message: "must be between #{@min_timeout} and #{@max_timeout}"
    )
  end

  @doc """
  Applies `attrs`, returning the updated struct and its changeset.

  Invalid fields keep their previous value, so a bad edit cannot leave the fetch
  button pointing at a size the agent would reject.
  """
  @spec apply(t(), map()) :: {t(), Ecto.Changeset.t()}
  def apply(controls, attrs) do
    changeset = %{changeset(controls, attrs) | action: :validate}

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, applied} -> {applied, changeset}
      {:error, changeset} -> {Ecto.Changeset.apply_changes(valid_part(changeset)), changeset}
    end
  end

  defp valid_part(changeset) do
    Enum.reduce(changeset.errors, changeset, fn {field, _}, acc ->
      Map.update!(acc, :changes, &Map.delete(&1, field))
    end)
  end
end
