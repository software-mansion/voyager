defmodule VoyagerWeb.SupervisionTreeLive.Diff do
  @moduledoc """
  Flatten the walker's nested tree into a key-addressable map and diff two such
  maps to produce a minimal `added` / `removed` / `updated` payload for the
  client-side renderer.

  Relationship edges (links / monitors / monitored-by) are flattened separately
  into an id-keyed map and diffed into `edges_added` / `edges_removed` — edges
  carry no mutable fields, so there is no "updated" case for them.

  Node keys:

    * real-pid node → `"<X.Y.Z>"` (matches `:erlang.pid_to_list/1`)
    * `:app` wrapper → `"app:<app_atom>"` (disambiguates from its root
      supervisor)
    * port node → `"port:<inspect(port)>"`
    * reference node → `"ref:<inspect(ref)>"`
    * ghost child (`pid: nil`) → `"<parent_key>::ghost::<inspect(child_id)>"`

  Edge keys → `"rel:<kind>:<from_key>-><to_key>"`.
  """

  @type flat_node :: %{
          key: String.t(),
          parent_key: String.t() | nil,
          name: term(),
          type: :app | :supervisor | :worker | :port | :reference,
          has_children?: boolean(),
          child_count: non_neg_integer(),
          info: map() | :dead | nil,
          children_keys: [String.t()] | :not_loaded
        }

  @type flat_map :: %{String.t() => flat_node()}

  @type edge :: %{id: String.t(), source: String.t(), target: String.t(), kind: String.t()}

  @type edge_map :: %{String.t() => edge()}

  @type patch :: %{optional(atom()) => term()}

  @type diff_result :: %{
          added: flat_map(),
          removed: [String.t()],
          updated: %{String.t() => patch()}
        }

  @type edge_diff_result :: %{
          edges_added: edge_map(),
          edges_removed: [String.t()]
        }

  @diff_fields [:name, :type, :has_children?, :child_count, :info, :children_keys]

  @doc """
  Flattens a walker result (`%{tree:, relations:, rel_nodes:}`) or a bare tree
  map into a key-addressable node map. Relationship-only nodes (`rel_nodes`)
  are added as parentless leaves.
  """
  @spec flatten(map() | nil) :: flat_map()
  def flatten(nil), do: %{}

  def flatten(%{tree: tree, rel_nodes: rel_nodes}) do
    base = flatten_tree(tree)
    Enum.reduce(rel_nodes, base, &flatten_rel_node/2)
  end

  def flatten(tree) when is_map(tree), do: flatten_tree(tree)

  defp flatten_tree(tree) when is_map(tree) do
    Enum.reduce(tree, %{}, fn {app, app_node}, acc ->
      flatten_app(app, app_node, acc)
    end)
  end

  defp flatten_app(app, app_node, acc) do
    app_key = "app:#{app}"

    {child_keys, acc} = flatten_children(app_node.children, app_key, acc)

    entry = %{
      key: app_key,
      parent_key: nil,
      name: app,
      type: :app,
      has_children?: app_node.has_children?,
      child_count: Map.get(app_node, :child_count, 0),
      info: Map.get(app_node, :info),
      children_keys: child_keys
    }

    Map.put(acc, app_key, entry)
  end

  defp flatten_children(:not_loaded, _parent_key, acc), do: {:not_loaded, acc}

  defp flatten_children(children, parent_key, acc) when is_list(children) do
    {rev_keys, acc} =
      Enum.reduce(children, {[], acc}, fn child, {keys, acc} ->
        {key, acc} = flatten_node(child, parent_key, acc)
        {[key | keys], acc}
      end)

    {Enum.reverse(rev_keys), acc}
  end

  defp flatten_node(node, parent_key, acc) do
    key = node_key(node, parent_key)

    {child_keys, acc} = flatten_children(node.children, key, acc)

    entry = %{
      key: key,
      parent_key: parent_key,
      name: node.name,
      type: node.type,
      has_children?: node.has_children?,
      child_count: Map.get(node, :child_count, 0),
      info: Map.get(node, :info),
      children_keys: child_keys
    }

    {key, Map.put(acc, key, entry)}
  end

  # Relationship-only nodes are parentless leaves. `put_new` ensures a target
  # that also exists in the supervision tree keeps its richer tree entry.
  defp flatten_rel_node(%{id: id} = node, acc) do
    key = id_key(id)

    entry = %{
      key: key,
      parent_key: nil,
      name: node.name,
      type: node.type,
      has_children?: false,
      child_count: 0,
      info: Map.get(node, :info),
      children_keys: :not_loaded
    }

    Map.put_new(acc, key, entry)
  end

  defp node_key(%{pid: pid}, _parent_key) when is_pid(pid), do: id_key(pid)

  defp node_key(%{pid: nil, name: child_id}, parent_key) do
    "#{parent_key}::ghost::#{inspect(child_id)}"
  end

  defp id_key(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp id_key(port) when is_port(port), do: "port:#{inspect(port)}"
  defp id_key(ref) when is_reference(ref), do: "ref:#{inspect(ref)}"

  @doc """
  Flattens a walker result's `relations` into an id-keyed edge map. Returns an
  empty map for bare tree input that carries no relations.
  """
  @spec relations(map()) :: edge_map()
  def relations(%{relations: relations}) when is_list(relations) do
    Map.new(relations, fn %{from: from, to: to, kind: kind} ->
      source = id_key(from)
      target = id_key(to)
      id = "rel:#{kind}:#{source}->#{target}"
      {id, %{id: id, source: source, target: target, kind: to_string(kind)}}
    end)
  end

  def relations(_), do: %{}

  @spec diff(flat_map(), flat_map()) :: diff_result()
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
