defmodule VoyagerWeb.SupervisionTreeLive.Diff do
  @moduledoc """
  Diffs two flat, key-addressable node maps produced by
  `Voyager.Services.SupervisionTree.Walker.walk/4` into a minimal
  `added` / `removed` / `updated` payload for the client-side renderer.
  """

  alias Voyager.Services.SupervisionTree.TreeNode

  @type flat_tree :: %{String.t() => TreeNode.t()}

  @type patch :: %{optional(atom()) => term()}

  @type diff_result :: %{
          added: flat_tree(),
          removed: [String.t()],
          updated: %{String.t() => patch()}
        }

  @diff_fields [:name, :type, :has_children, :child_count, :info, :children_keys]

  @spec diff(flat_tree(), flat_tree()) :: diff_result()
  def diff(prev, curr) when is_map(prev) and is_map(curr) do
    {added, updated} = Enum.reduce(curr, {%{}, %{}}, &classify_node(&1, &2, prev))

    removed =
      prev
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(curr, &1))

    %{added: added, removed: removed, updated: updated}
  end

  defp classify_node({key, node}, {add_acc, upd_acc}, prev) do
    case Map.fetch(prev, key) do
      :error -> {Map.put(add_acc, key, node), upd_acc}
      {:ok, prev_node} -> patch_node(prev_node, node, key, add_acc, upd_acc)
    end
  end

  defp patch_node(prev_node, node, key, add_acc, upd_acc) do
    case build_patch(prev_node, node) do
      patch when map_size(patch) == 0 -> {add_acc, upd_acc}
      patch -> {add_acc, Map.put(upd_acc, key, patch)}
    end
  end

  defp build_patch(prev, curr) do
    Enum.reduce(@diff_fields, %{}, fn field, patch ->
      pv = Map.get(prev, field)
      cv = Map.get(curr, field)
      if pv == cv, do: patch, else: Map.put(patch, field, cv)
    end)
  end
end
