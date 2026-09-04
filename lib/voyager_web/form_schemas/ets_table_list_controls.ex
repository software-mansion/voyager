defmodule VoyagerWeb.FormSchemas.EtsTableListControls do
  @moduledoc """
  Controls form for the ETS table list: the search, the request timeout and
  which columns to show.

  Only `timeout` reaches the node. `search` and `columns` shape whatever the
  last fetch returned; `required_columns/0` are always shown, since the name
  identifies the row and memory is the default ranking.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VoyagerWeb.EtsTablesLive.Query

  @min_timeout 1_000
  @max_timeout 30_000
  @default_timeout 5_000

  @primary_key false
  embedded_schema do
    field :search, :string, default: ""
    field :timeout, :integer, default: @default_timeout
    field :columns, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{}

  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @spec required_columns() :: [atom()]
  def required_columns, do: Query.required_attrs()

  @spec optional_columns() :: [atom()]
  def optional_columns, do: Query.optional_attrs()

  @doc "The form's defaults, as a struct."
  @spec default() :: t()
  def default, do: %__MODULE__{columns: Enum.map(Query.default_attrs(), &to_string/1)}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(controls \\ default(), attrs \\ %{}) do
    controls
    |> cast(normalize(attrs), [:search, :timeout, :columns])
    |> update_change(:search, &String.trim/1)
    |> update_change(:columns, &known_columns/1)
    |> validate_required([:timeout])
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
  The columns to show: the required ones plus the selected, as atoms in a
  fixed order.
  """
  @spec columns(t()) :: [atom()]
  def columns(%__MODULE__{columns: columns}) do
    selected = Enum.map(columns, &safe_atom/1)

    Enum.filter(required_columns() ++ optional_columns(), fn column ->
      column in required_columns() or column in selected
    end)
  end

  @doc "Options for the columns multiselect, as `{value, label, locked?}`."
  @spec column_options((atom() -> String.t())) :: [{String.t(), String.t(), boolean()}]
  def column_options(label_fun) do
    Enum.map(required_columns(), &{to_string(&1), label_fun.(&1), true}) ++
      Enum.map(optional_columns(), &{to_string(&1), label_fun.(&1), false})
  end

  # A null `search` from localStorage would reach `String.trim/1`. A blank
  # `timeout` goes the other way: `cast/4` skips "", nil is a change
  # `validate_required/2` can report.
  defp normalize(attrs) do
    attrs = if Map.get(attrs, "search") == nil, do: Map.delete(attrs, "search"), else: attrs

    if Map.get(attrs, "timeout") == "", do: Map.put(attrs, "timeout", nil), else: attrs
  end

  # Drops the fields that failed validation, so the rest still applies.
  defp valid_part(changeset) do
    Enum.reduce(changeset.errors, changeset, fn {field, _}, acc ->
      Map.update!(acc, :changes, &Map.delete(&1, field))
    end)
  end

  defp known_columns(columns) when is_list(columns), do: Enum.filter(columns, &safe_atom/1)
  defp known_columns(_columns), do: []

  defp safe_atom(value) do
    Enum.find(required_columns() ++ optional_columns(), &(to_string(&1) == value))
  end
end
