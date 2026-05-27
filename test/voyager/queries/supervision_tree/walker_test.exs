defmodule Voyager.Queries.SupervisionTree.WalkerTest do
  use ExUnit.Case, async: false

  alias Voyager.Queries.SupervisionTree.Walker
  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)
    on_exit(fn -> RemoteFixture.stop_peer!(peer) end)
    {:ok, peer: peer}
  end

  describe "walk/4 depth=1, no expanded" do
    test "app node exists with root sup as its child; mid sups are stubs", %{peer: peer} do
      node = peer.node

      {:ok, tree, []} = Walker.walk(node, [:voyager_fixture], 1, MapSet.new())

      assert Map.has_key?(tree, :voyager_fixture)

      app_node = tree[:voyager_fixture]
      assert app_node.type == :app
      assert app_node.has_children?
      assert app_node.child_count == 1
      assert [root_node] = app_node.children

      assert root_node.type == :supervisor
      assert is_list(root_node.children)
      assert length(root_node.children) == 2
      assert root_node.child_count == 2

      for mid_node <- root_node.children do
        assert mid_node.type == :supervisor
        assert mid_node.has_children?
        assert mid_node.children == :not_loaded
        # stubbed via depth — count was fetched via count_children
        assert is_integer(mid_node.child_count)
        assert mid_node.child_count > 0
      end
    end
  end

  describe "walk/4 depth=2" do
    test "mid sups show workers; workers are leaf stubs", %{peer: peer} do
      node = peer.node

      {:ok, tree, []} = Walker.walk(node, [:voyager_fixture], 2, MapSet.new())

      app_node = tree[:voyager_fixture]
      [root_node] = app_node.children

      for mid_node <- root_node.children do
        assert mid_node.type == :supervisor
        assert is_list(mid_node.children)
        assert length(mid_node.children) == 2

        for worker_node <- mid_node.children do
          assert worker_node.type == :worker
          refute worker_node.has_children?
          assert worker_node.children == :not_loaded
          assert worker_node.child_count == 0
        end
      end
    end
  end

  describe "walk/4 depth=0 with expanded mid-sup pid" do
    test "expanded mid sup has its children loaded even though depth=0", %{peer: peer} do
      node = peer.node

      mid_sup_a_pid =
        :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])

      assert is_pid(mid_sup_a_pid)

      expanded = MapSet.new([mid_sup_a_pid])

      # depth=0 means root sup gets a stub, but since root sup is also walked
      # (depth=0 applied after app wrapper), let's use depth=1 so root sup
      # is fetched, then MidSupA (depth=0) is forced via expanded
      {status, tree, _errors} = Walker.walk(node, [:voyager_fixture], 1, expanded)

      assert status in [:ok, :partial]

      app_node = tree[:voyager_fixture]
      [root_node] = app_node.children

      mid_sup_a_node =
        Enum.find(root_node.children, fn child ->
          child.pid == mid_sup_a_pid
        end)

      refute is_nil(mid_sup_a_node)
      assert mid_sup_a_node.type == :supervisor
      # MidSupA was in expanded, so its children should be loaded
      assert is_list(mid_sup_a_node.children)
      assert length(mid_sup_a_node.children) == 2

      for worker_node <- mid_sup_a_node.children do
        assert worker_node.type == :worker
      end
    end
  end

  describe "walk/4 app not running" do
    test "returns partial with error for nonexistent app", %{peer: peer} do
      node = peer.node

      {:partial, tree, errors} = Walker.walk(node, [:nonexistent_app_xyz], 3, MapSet.new())

      assert tree == %{}
      assert [{:root_supervisor, :nonexistent_app_xyz, :not_running}] = errors
    end

    test "returns ok tree for running apps alongside error for nonexistent", %{peer: peer} do
      node = peer.node

      {:partial, tree, errors} =
        Walker.walk(node, [:voyager_fixture, :nonexistent_app_xyz], 1, MapSet.new())

      assert Map.has_key?(tree, :voyager_fixture)
      refute Map.has_key?(tree, :nonexistent_app_xyz)

      assert Enum.any?(errors, fn
               {:root_supervisor, :nonexistent_app_xyz, :not_running} -> true
               _ -> false
             end)
    end
  end
end
