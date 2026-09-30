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

  @diff_fields [:parent_key, :name, :type, :child_count, :info, :children_keys]

  @spec diff(flat_tree(), flat_tree()) :: diff_result()
  def diff(prev, curr) when is_map(prev) and is_map(curr) do
    updated =
      prev
      |> Map.intersect(curr, fn _key, prev_node, node -> build_patch(prev_node, node) end)
      |> Map.reject(fn {_key, patch} -> map_size(patch) == 0 end)

    %{
      added: Map.drop(curr, Map.keys(prev)),
      removed: Map.keys(prev) -- Map.keys(curr),
      updated: updated
    }
  end

  @spec diff_relations(edge_map(), edge_map()) :: edge_diff_result()
  def diff_relations(prev, curr) when is_map(prev) and is_map(curr) do
    %{
      edges_added: Map.drop(curr, Map.keys(prev)),
      edges_removed: Map.keys(prev) -- Map.keys(curr)
    }
  end

  defp build_patch(prev, curr) do
    curr
    |> Map.take(@diff_fields)
    |> Map.reject(fn {field, value} -> Map.get(prev, field) == value end)
  end
end
