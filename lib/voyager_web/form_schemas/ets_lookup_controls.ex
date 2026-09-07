defmodule VoyagerWeb.FormSchemas.EtsLookupControls do
  @moduledoc """
  Controls form for the ETS record sidebar: the term budget a lookup may spend
  and how long to wait for it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @min_budget 100
  @max_budget 50_000
  @default_budget Voyager.Agent.default_budget()
  @min_timeout 1_000
  @max_timeout 30_000
  @default_timeout 5_000

  @primary_key false
  embedded_schema do
    field :budget, :integer, default: @default_budget
    field :timeout, :integer, default: @default_timeout
  end

  @type t :: %__MODULE__{}

  @spec budget_bounds() :: {pos_integer(), pos_integer()}
  def budget_bounds, do: {@min_budget, @max_budget}

  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(controls \\ default(), attrs \\ %{}) do
    controls
    |> cast(attrs, [:budget, :timeout])
    |> validate_required([:budget, :timeout])
    |> validate_number(:budget,
      greater_than_or_equal_to: @min_budget,
      less_than_or_equal_to: @max_budget,
      message: "must be between #{@min_budget} and #{@max_budget}"
    )
    |> validate_number(:timeout,
      greater_than_or_equal_to: @min_timeout,
      less_than_or_equal_to: @max_timeout,
      message: "must be between #{@min_timeout} and #{@max_timeout}"
    )
  end

  @doc """
  Applies `attrs`, returning the updated struct and its changeset.

  Invalid fields keep their previous value, so the refetch button always sends
  values the agent accepts.
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
