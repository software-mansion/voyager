defmodule VoyagerWeb.FormSchemas.SupervisionTreeControls do
  @moduledoc """
  Controls form for the supervision-tree view: which applications to inspect
  and how deep to walk by default.

  `apps` is stored as a list of strings (matching the checkbox values in the
  template) and is filtered against the caller-supplied list of available
  application atoms — so a malicious or stale submission cannot smuggle in an
  arbitrary atom that happens to exist in the VM.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_apps 20
  @min_depth 2
  @default_depth 3

  @primary_key false
  embedded_schema do
    field :apps, {:array, :string}, default: []
    field :depth, :integer, default: @default_depth
  end

  @spec max_apps() :: pos_integer()
  def max_apps, do: @max_apps

  @spec min_depth() :: pos_integer()
  def min_depth, do: @min_depth

  @spec default_depth() :: pos_integer()
  def default_depth, do: @default_depth

  @spec changeset(map(), [atom()]) :: Ecto.Changeset.t()
  def changeset(attrs, available_apps) when is_list(available_apps) do
    %__MODULE__{}
    |> cast(attrs, [:apps, :depth])
    |> update_change(:apps, &filter_known(&1, available_apps))
    |> validate_number(:depth,
      greater_than_or_equal_to: @min_depth,
      message: "min #{@min_depth}"
    )
  end

  @doc """
  Returns `{apps_as_atoms, truncated?}`. Callers can show a flash when
  `truncated?` is true.
  """
  @spec apps_from_changeset(Ecto.Changeset.t()) :: {[atom()], boolean()}
  def apps_from_changeset(changeset) do
    apps = get_field(changeset, :apps) || []
    truncated? = length(apps) > @max_apps
    {apps |> Enum.take(@max_apps) |> Enum.map(&String.to_existing_atom/1), truncated?}
  end

  defp filter_known(strings, available) when is_list(strings) do
    available_strings = MapSet.new(available, &to_string/1)
    Enum.filter(strings, &MapSet.member?(available_strings, &1))
  end

  defp filter_known(_, _), do: []
end
