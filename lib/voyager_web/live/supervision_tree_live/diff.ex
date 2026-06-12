defmodule VoyagerWeb.SupervisionTreeLive.Diff do
  @moduledoc """
  Diffs two flat, key-addressable node maps (and their edge maps) produced by
  `Voyager.Services.SupervisionTree.Walker.walk/4` into a minimal
  `added` / `removed` / `updated` payload for the client-side renderer.

  Relationship edges (links / monitors / monitored-by) are diffed separately
  into `edges_added` / `edges_removed` — edges carry no mutable fields, so there
  is no "updated" case for them.
  """

  alias Voyager.Services.SupervisionTree.Edge
  alias Voyager.Services.SupervisionTree.TreeNode

  @type flat_tree :: %{String.t() => TreeNode.t()}

  @type edge_map :: %{String.t() => Edge.t()}

  @type patch :: %{optional(atom()) => term()}

  @type diff_result :: %{
          added: flat_tree(),
          removed: [String.t()],
          updated: %{String.t() => patch()}
        }

  @type edge_diff_result :: %{
          edges_added: edge_map(),
          edges_removed: [String.t()]
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

  @doc """
  Diffs two edge maps into `edges_added` (full edge objects) and
  `edges_removed` (ids). Edges have no mutable fields.
  """
  @spec diff_relations(edge_map(), edge_map()) :: edge_diff_result()
  def diff_relations(prev, curr) when is_map(prev) and is_map(curr) do
    edges_added =
      curr
      |> Enum.reject(fn {id, _edge} -> Map.has_key?(prev, id) end)
      |> Map.new()

    edges_removed =
      prev
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(curr, &1))

    %{edges_added: edges_added, edges_removed: edges_removed}
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
