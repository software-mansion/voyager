defmodule VoyagerWeb.SupervisionTreeLive.Selection do
  @moduledoc """
  Pure selection logic over the flat node map produced by the supervision
  tree walk: key lookups, root-path computation, and the decision of what a
  details-panel link jump should do.

  Knows nothing about sockets — `VoyagerWeb.SupervisionTreeLive` applies the
  returned instructions (assigns, `push_event`, fetches).
  """

  alias Voyager.Services.SupervisionTree.TreeNode

  @type flat_tree :: %{String.t() => TreeNode.t()} | nil
  @type link_identifier :: pid() | port()

  @type jump ::
          {:select, TreeNode.t()}
          | {:select_placeholder, TreeNode.t()}
          | {:expand_and_reveal, TreeNode.t(), TreeNode.t()}

  @doc """
  Finds the node for `key` in the flat tree.

  App wrappers are keyed `app:<name>` while PID-links look up `<X.Y.Z>`, so a
  direct miss falls back to matching the live pid (preferring the `:app`
  wrapper) so those nodes still resolve.
  """
  @spec lookup(flat_tree(), String.t()) :: TreeNode.t() | nil
  def lookup(nil, _key), do: nil
  def lookup(flat, key), do: Map.get(flat, key) || find_by_pid_key(flat, key)

  @doc """
  Returns the `[key, ..., root_key]` path for a node in the flat tree, or `[]`
  when the key is missing.
  """
  @spec path_to_root(%{String.t() => TreeNode.t()}, String.t()) :: [String.t()]
  def path_to_root(flat, key), do: path_to_root(flat, key, [])

  @doc """
  Builds a stand-in `TreeNode` for an identifier that is not part of the
  loaded walk, so the details panel can still display it.
  """
  @spec placeholder(link_identifier()) :: TreeNode.t()
  def placeholder(pid) when is_pid(pid) do
    %TreeNode{key: TreeNode.key(pid), pid: pid, name: pid, type: :process, placeholder?: true}
  end

  def placeholder(port) when is_port(port) do
    %TreeNode{key: TreeNode.key(port), name: port, type: :port, placeholder?: true}
  end

  @doc """
  Decides what clicking a details-panel link should do.

    * `{:select, node}` — the target is in the tree: select and focus it
    * `{:select_placeholder, node}` — not in the tree and nothing to expand:
      show the stand-in node only
    * `{:expand_and_reveal, placeholder, stub}` — not in the tree, but `stub`
      (the node the click came from, or a collapsed supervisor that links the
      target) can be expanded to reveal it: show the stand-in, expand the
      stub, and re-select once the fetch lands

  `from` is the currently selected node (where the click originated) and
  `expanded_pids` the set of already-expanded supervisor pids.
  """
  @spec resolve_jump(flat_tree(), link_identifier(), TreeNode.t() | nil, MapSet.t(pid())) ::
          jump()
  def resolve_jump(flat, identifier, from, expanded_pids) do
    in_tree = lookup(flat, TreeNode.key(identifier))
    placeholder = placeholder(identifier)

    cond do
      in_tree ->
        {:select, in_tree}

      stub = stub_to_expand(flat, identifier, from, expanded_pids) ->
        {:expand_and_reveal, placeholder, stub}

      true ->
        {:select_placeholder, placeholder}
    end
  end

  # Expanding a stub to reveal a PID-link is the same work as a manual +/-
  # expand: one `which_children` plus hydrate for that supervisor's direct
  # children. Only pids can be revealed this way.
  defp stub_to_expand(flat, identifier, from, expanded_pids) when is_pid(identifier) do
    stub =
      if expandable_stub?(from) do
        from
      else
        find_stub_linking_to(flat, identifier)
      end

    if stub && not MapSet.member?(expanded_pids, stub.pid), do: stub
  end

  defp stub_to_expand(_flat, _identifier, _from, _expanded_pids), do: nil

  defp expandable_stub?(%TreeNode{
         type: type,
         pid: pid,
         children_keys: :not_loaded,
         child_count: n
       })
       when type in [:supervisor, :app] and is_pid(pid) and is_integer(n) and n > 0,
       do: true

  defp expandable_stub?(_), do: false

  defp find_stub_linking_to(flat, identifier) when is_map(flat) do
    Enum.find_value(flat, fn {_key, node} ->
      if expandable_stub?(node) and linked_to?(node, identifier), do: node
    end)
  end

  defp find_stub_linking_to(_flat, _identifier), do: nil

  defp linked_to?(%TreeNode{info: %{links: links}}, identifier) when is_list(links),
    do: identifier in links

  defp linked_to?(_node, _identifier), do: false

  defp find_by_pid_key(flat, key) do
    nodes =
      for {_k, %TreeNode{pid: pid} = n} <- flat, is_pid(pid), TreeNode.key(pid) == key, do: n

    Enum.find(nodes, &(&1.type == :app)) || List.first(nodes)
  end

  defp path_to_root(_flat, nil, acc), do: Enum.reverse(acc)

  defp path_to_root(flat, key, acc) do
    case Map.fetch(flat, key) do
      :error -> Enum.reverse(acc)
      {:ok, node} -> path_to_root(flat, node.parent_key, [key | acc])
    end
  end
end
