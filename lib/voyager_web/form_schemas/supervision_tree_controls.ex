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

  @spec min_depth() :: pos_integer()
  def min_depth, do: @min_depth

  @spec default_depth() :: pos_integer()
  def default_depth, do: @default_depth

  @spec changeset(map(), [atom()]) :: Ecto.Changeset.t()
  def changeset(attrs, available_apps) when is_list(available_apps) do
    %__MODULE__{}
    |> cast(attrs, [:apps, :depth])
    |> update_change(:apps, &filter_map_known(&1, available_apps))
    |> validate_length(:apps,
      max: @max_apps,
      message: "Only #{@max_apps} applications can be selected at once."
    )
    |> validate_number(:depth,
      greater_than_or_equal_to: @min_depth,
      message: "min #{@min_depth}"
    )
  end

  defp filter_map_known(apps, available) when is_list(apps) do
    available = MapSet.new(available, &to_string/1)

    apps
    |> Enum.filter(&MapSet.member?(available, &1))
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp filter_map_known(_, _), do: []
end
