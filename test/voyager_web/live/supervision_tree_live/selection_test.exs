defmodule VoyagerWeb.SupervisionTreeLive.SelectionTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.SupervisionTreeLive.Selection

  defp pid(str), do: str |> String.to_charlist() |> :erlang.list_to_pid()

  defp node!(key, attrs) do
    struct!(TreeNode, Map.merge(%{key: key, type: :worker}, Map.new(attrs)))
  end

  defp tree(nodes), do: Map.new(nodes, &{&1.key, &1})

  describe "lookup/2" do
    test "finds a node by its key" do
      node = node!("<0.10.0>", pid: pid("<0.10.0>"))
      assert Selection.lookup(tree([node]), "<0.10.0>") == node
    end

    test "falls back to matching the live pid for differently-keyed nodes" do
      master = pid("<0.20.0>")
      app = node!("app:demo", type: :app, pid: master)

      assert Selection.lookup(tree([app]), TreeNode.key(master)) == app
    end

    test "prefers the app wrapper when several fallback nodes share a pid" do
      shared = pid("<0.21.0>")
      ghost = node!("parent::ghost::child", type: :worker, pid: shared)
      app = node!("app:demo", type: :app, pid: shared)

      assert %TreeNode{type: :app} =
               Selection.lookup(tree([ghost, app]), TreeNode.key(shared))
    end

    test "returns nil for a missing key or missing tree" do
      assert Selection.lookup(tree([]), "<0.10.0>") == nil
      assert Selection.lookup(nil, "<0.10.0>") == nil
    end
  end

  describe "path_to_root/2" do
    test "returns the node-to-root key path" do
      root = node!("root", type: :supervisor, pid: pid("<0.30.0>"))
      mid = node!("mid", type: :supervisor, pid: pid("<0.31.0>"), parent_key: "root")
      leaf = node!("leaf", pid: pid("<0.32.0>"), parent_key: "mid")

      assert Selection.path_to_root(tree([root, mid, leaf]), "leaf") == ["leaf", "mid", "root"]
    end

    test "returns [] for a missing key, empty key, or missing tree" do
      root = node!("root", type: :supervisor)

      assert Selection.path_to_root(tree([root]), "nope") == []
      assert Selection.path_to_root(tree([root]), "") == []
      assert Selection.path_to_root(nil, "root") == []
    end
  end

  describe "placeholder/1" do
    test "builds a process node for a pid" do
      p = pid("<0.40.0>")

      assert %TreeNode{key: key, pid: ^p, name: ^p, type: :process, placeholder?: true} =
               Selection.placeholder(p)

      assert key == TreeNode.key(p)
    end

    test "builds a port node for a port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      assert %TreeNode{key: key, type: :port, name: ^port, placeholder?: true} =
               Selection.placeholder(port)

      assert key == inspect(port)
    end

    test "returns nil for references and other terms" do
      assert Selection.placeholder(make_ref()) == nil
      assert Selection.placeholder(:other) == nil
    end
  end

  describe "resolve_jump/4" do
    test "selects the node when the identifier is in the tree" do
      p = pid("<0.50.0>")
      node = node!(TreeNode.key(p), pid: p)

      assert Selection.resolve_jump(tree([node]), p, nil, MapSet.new()) == {:select, node}
    end

    test "ignores identifiers that cannot be found or displayed" do
      assert Selection.resolve_jump(tree([]), make_ref(), nil, MapSet.new()) == :ignore
    end

    test "selects a placeholder when nothing can be expanded" do
      p = pid("<0.51.0>")

      assert {:select_placeholder, %TreeNode{type: :process, pid: ^p}} =
               Selection.resolve_jump(tree([]), p, nil, MapSet.new())
    end

    test "expands the origin node when it is a collapsed supervisor stub" do
      target = pid("<0.52.0>")
      from = node!("<0.53.0>", type: :supervisor, pid: pid("<0.53.0>"), child_count: 2)

      assert {:expand_and_reveal, %TreeNode{type: :process, pid: ^target}, ^from} =
               Selection.resolve_jump(tree([from]), target, from, MapSet.new())
    end

    test "expands a stub that links to the target when the origin is not a stub" do
      target = pid("<0.54.0>")
      from = node!("<0.55.0>", pid: pid("<0.55.0>"))

      stub =
        node!("<0.56.0>",
          type: :supervisor,
          pid: pid("<0.56.0>"),
          child_count: 1,
          info: %{links: [target]}
        )

      assert {:expand_and_reveal, _placeholder, ^stub} =
               Selection.resolve_jump(tree([from, stub]), target, from, MapSet.new())
    end

    test "falls back to a placeholder when the stub is already expanded" do
      target = pid("<0.57.0>")
      stub_pid = pid("<0.58.0>")
      from = node!("<0.58.0>", type: :supervisor, pid: stub_pid, child_count: 1)

      assert {:select_placeholder, _placeholder} =
               Selection.resolve_jump(tree([from]), target, from, MapSet.new([stub_pid]))
    end

    test "never expands to reveal a port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      from = node!("<0.59.0>", type: :supervisor, pid: pid("<0.59.0>"), child_count: 1)

      assert {:select_placeholder, %TreeNode{type: :port}} =
               Selection.resolve_jump(tree([from]), port, from, MapSet.new())
    end
  end
end
