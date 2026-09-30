defmodule VoyagerWeb.FormSchemas do
  @moduledoc false

  @doc """
  Applies the changes that pass validation; a field that fails keeps its previous
  value. Returns the struct with the changeset, marked `:validate` so `to_form/2`
  shows its errors.
  """
  @spec apply_valid(Ecto.Changeset.t()) :: {struct(), Ecto.Changeset.t()}
  def apply_valid(changeset) do
    changeset = %{changeset | action: :validate}
    valid_changes = Map.drop(changeset.changes, Keyword.keys(changeset.errors))

    {Ecto.Changeset.apply_changes(%{changeset | changes: valid_changes}), changeset}
  end
end
