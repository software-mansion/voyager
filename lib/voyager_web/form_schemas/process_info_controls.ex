defmodule VoyagerWeb.FormSchemas.ProcessInfoControls do
  @moduledoc """
  Controls form for one section of the process info page: how much the remote
  node is asked for and how long it may take.

  A section declares which of `timeout`, `budget` and `limit` it takes through
  `fields`; those are the fields it renders, validates and requires. A field the
  section does not declare is ignored even if a submission carries it.

  Out-of-range or blank input is rejected rather than clamped: the section keeps
  the last good value and the form shows the error.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @min_timeout 1_000
  @max_timeout 30_000
  @min_budget 100
  @min_limit 1
  @max_limit 1_000

  @fields ~w(timeout budget limit)a

  @primary_key false
  embedded_schema do
    field :section, Ecto.Enum, values: ~w(info relations state messages dictionary)a
    field :fields, {:array, Ecto.Enum}, values: @fields, default: @fields
    field :timeout, :integer
    field :budget, :integer
    field :limit, :integer
  end

  @type t :: %__MODULE__{}

  @doc "Whether the section takes this control."
  @spec field?(t(), atom()) :: boolean()
  def field?(%__MODULE__{fields: fields}, field), do: field in fields

  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @spec budget_bounds() :: {pos_integer(), nil}
  def budget_bounds, do: {@min_budget, nil}

  @spec limit_bounds() :: {pos_integer(), pos_integer()}
  def limit_bounds, do: {@min_limit, @max_limit}

  @doc """
  Builds a section's controls from the values it takes; the keys given are the
  fields the section has.
  """
  @spec new(atom(), keyword()) :: t()
  def new(section, opts) do
    fields = Enum.filter(@fields, &Keyword.has_key?(opts, &1))

    struct!(%__MODULE__{section: section, fields: fields}, Keyword.take(opts, fields))
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(controls, attrs \\ %{}) do
    controls
    |> cast(blank_to_nil(attrs), editable_fields(controls))
    |> validate_required(editable_fields(controls))
    |> validate_number(:timeout,
      greater_than_or_equal_to: @min_timeout,
      less_than_or_equal_to: @max_timeout,
      message: "must be between #{@min_timeout} and #{@max_timeout}"
    )
    |> validate_number(:budget,
      greater_than_or_equal_to: @min_budget,
      message: "must be at least #{@min_budget}"
    )
    |> validate_number(:limit,
      greater_than_or_equal_to: @min_limit,
      less_than_or_equal_to: @max_limit,
      message: "must be between #{@min_limit} and #{@max_limit}"
    )
  end

  @doc """
  Applies `attrs`, returning the updated struct and its changeset.

  A field that fails validation keeps its previous value, so the section stays
  fetchable while the form shows the error.
  """
  @spec apply(t(), map()) :: {t(), Ecto.Changeset.t()}
  def apply(controls, attrs) do
    # `:validate` on the changeset either way: `to_form/2` only surfaces errors
    # once an action is set.
    changeset = %{changeset(controls, attrs) | action: :validate}

    case apply_action(changeset, :validate) do
      {:ok, applied} -> {applied, changeset}
      {:error, changeset} -> {apply_changes(valid_part(changeset)), changeset}
    end
  end

  @doc """
  Applies stored values from the client, ignoring anything invalid.

  The storage is hand-editable, and a section that has since lost a field would
  still have it stored, so only valid changes are kept and no error surfaces.
  """
  @spec restore(t(), map()) :: t()
  def restore(controls, attrs) when is_map(attrs) do
    controls |> changeset(attrs) |> valid_part() |> apply_changes()
  end

  def restore(controls, _attrs), do: controls

  # `nil` for a section's missing field, "" from a cleared input: both are a
  # change `validate_required/2` can report, rather than a silent no-op.
  defp blank_to_nil(attrs) do
    Map.new(attrs, fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp editable_fields(%__MODULE__{fields: fields}), do: fields

  # Drops the fields that failed validation, so the rest still applies.
  defp valid_part(changeset) do
    Enum.reduce(changeset.errors, changeset, fn {field, _error}, acc ->
      Map.update!(acc, :changes, &Map.delete(&1, field))
    end)
  end
end
