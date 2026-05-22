defmodule VoyagerWeb.SupervisionTreeLive.Diff do
  @moduledoc """
  Flatten the walker's nested tree into a key-addressable map and diff two such
  maps to produce a minimal `added` / `removed` / `updated` payload for the
  client-side renderer.

  Keys:

    * real-pid node → `"<X.Y.Z>"` (matches `:erlang.pid_to_list/1`)
    * `:app` wrapper → `"app:<app_atom>"` (disambiguates from root supervisor,
      which shares the pid)
    * ghost child (`pid: nil`) → `"<parent_key>::ghost::<inspect(child_id)>"`
  """

  @type flat_node :: %{
          key: String.t(),
          parent_key: String.t() | nil,
          name: term(),
          type: :app | :supervisor | :worker,
          has_children?: boolean(),
          child_count: non_neg_integer(),
          info: map() | :dead | nil,
          children_keys: [String.t()] | :not_loaded
        }

  @type flat_map :: %{String.t() => flat_node()}

  @type patch :: %{optional(atom()) => term()}

  @type diff_result :: %{
          added: flat_map(),
          removed: [String.t()],
          updated: %{String.t() => patch()}
        }

  @diff_fields [:name, :type, :has_children?, :child_count, :info, :children_keys]

  @spec flatten(map() | nil) :: flat_map()
  def flatten(nil), do: %{}

  def flatten(tree) when is_map(tree) do
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

  defp node_key(%{pid: pid}, _parent_key) when is_pid(pid) do
    pid |> :erlang.pid_to_list() |> List.to_string()
  end

  defp node_key(%{pid: nil, name: child_id}, parent_key) do
    "#{parent_key}::ghost::#{inspect(child_id)}"
  end

  @spec diff(flat_map(), flat_map()) :: diff_result()
  def diff(prev, curr) when is_map(prev) and is_map(curr) do
    {added, updated} =
      Enum.reduce(curr, {%{}, %{}}, fn {key, node}, {add_acc, upd_acc} ->
        case Map.fetch(prev, key) do
          :error ->
            {Map.put(add_acc, key, node), upd_acc}

          {:ok, prev_node} ->
            case build_patch(prev_node, node) do
              patch when map_size(patch) == 0 -> {add_acc, upd_acc}
              patch -> {add_acc, Map.put(upd_acc, key, patch)}
            end
        end
      end)

    removed =
      prev
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(curr, &1))

    %{added: added, removed: removed, updated: updated}
  end

  defp build_patch(prev, curr) do
    Enum.reduce(@diff_fields, %{}, fn field, patch ->
      pv = Map.get(prev, field)
      cv = Map.get(curr, field)
      if pv == cv, do: patch, else: Map.put(patch, field, cv)
    end)
  end
end
