defmodule VoyagerWeb.FormSchemas.ProcessListControls do
  @moduledoc """
  Controls form for the process list: what to fetch from the remote node and
  which columns to show.

  `columns` is stored as a list of strings (matching the checkbox values in the
  template) and filtered against the allowlist, so a stale or hand-edited
  submission cannot smuggle in an arbitrary atom. `required_columns/0` are
  always present in the result — they back the pid and the default ranking, so
  the table cannot render without them.

  Only `search`, `limit` and `timeout` reach the node; `columns` selects what is
  fetched per process but is applied to whatever the last fetch returned.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Voyager.Queries.Processes

  @limits [25, 50, 100, 250, 500, 1_000]
  @default_limit 100
  @min_timeout 1_000
  @max_timeout 30_000
  @default_timeout 5_000

  @primary_key false
  embedded_schema do
    field :search, :string, default: ""
    field :limit, :integer, default: @default_limit
    field :timeout, :integer, default: @default_timeout
    field :columns, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{}

  @spec limit_options() :: [pos_integer()]
  def limit_options, do: @limits

  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @spec required_columns() :: [atom()]
  def required_columns, do: Processes.required_attrs()

  @spec optional_columns() :: [atom()]
  def optional_columns, do: Processes.optional_attrs()

  @doc "The form's defaults, as a struct."
  @spec default() :: t()
  def default do
    %__MODULE__{columns: Enum.map(Processes.default_attrs(), &to_string/1)}
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(controls \\ default(), attrs \\ %{}) do
    controls
    |> cast(attrs, [:search, :limit, :timeout, :columns])
    |> update_change(:search, &String.trim/1)
    |> update_change(:columns, &filter_known/1)
    |> validate_inclusion(:limit, @limits, message: "must be one of #{Enum.join(@limits, ", ")}")
    |> validate_number(:timeout,
      greater_than_or_equal_to: @min_timeout,
      less_than_or_equal_to: @max_timeout,
      message: "must be between #{@min_timeout} and #{@max_timeout}"
    )
  end

  @doc """
  Applies `attrs`, returning the updated struct and its changeset.

  Invalid fields keep their previous value so the table stays usable while the
  form shows the error.
  """
  @spec apply(t(), map()) :: {t(), Ecto.Changeset.t()}
  def apply(controls, attrs) do
    # `:validate` on the changeset either way: `to_form/2` only surfaces errors
    # once an action is set.
    changeset = %{changeset(controls, attrs) | action: :validate}

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, applied} -> {applied, changeset}
      {:error, changeset} -> {Ecto.Changeset.apply_changes(valid_part(changeset)), changeset}
    end
  end

  @doc """
  The attributes to request per process: the selected columns plus the required
  ones, as atoms.
  """
  @spec attrs(t()) :: [atom()]
  def attrs(%__MODULE__{columns: columns}) do
    columns
    |> Enum.map(&safe_atom/1)
    |> Processes.clamp_attrs()
  end

  @doc "Options for the columns multiselect, as `{value, label, locked?}`."
  @spec column_options((atom() -> String.t())) :: [{String.t(), String.t(), boolean()}]
  def column_options(label_fun) do
    Enum.map(required_columns(), &{to_string(&1), label_fun.(&1), true}) ++
      Enum.map(optional_columns(), &{to_string(&1), label_fun.(&1), false})
  end

  # Drops the fields that failed validation, so the rest still applies.
  defp valid_part(changeset) do
    Enum.reduce(changeset.errors, changeset, fn {field, _}, acc ->
      Map.update!(acc, :changes, &Map.delete(&1, field))
    end)
  end

  defp filter_known(columns) when is_list(columns) do
    known = MapSet.new(required_columns() ++ optional_columns(), &to_string/1)

    Enum.filter(columns, &MapSet.member?(known, &1))
  end

  defp filter_known(_columns), do: []

  defp safe_atom(value) do
    Enum.find(required_columns() ++ optional_columns(), &(to_string(&1) == value))
  end
end
