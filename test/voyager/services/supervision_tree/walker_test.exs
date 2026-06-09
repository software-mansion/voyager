defmodule Voyager.Services.SupervisionTree.WalkerTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.SupervisionTree.Walker
  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)
    on_exit(fn -> RemoteFixture.stop_peer!(peer) end)
    {:ok, peer: peer}
  end

  # Returns `{mid_sup_a_pid, [worker_pids]}` for MidSupA on the peer node.
  defp midsup_a_workers(node) do
    mid_a = :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])
    children = :erpc.call(node, :supervisor, :which_children, [mid_a])
    pids = Enum.map(children, fn {_id, pid, _type, _mods} -> pid end)
    {mid_a, pids}
  end

  describe "walk/4 depth=2, no expanded" do
    test "app node exists with root sup as its child; mid sups are stubs", %{peer: peer} do
      node = peer.node

      {:ok, %{tree: tree}, []} = Walker.walk(node, [:voyager_fixture], 2, MapSet.new())

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

  describe "walk/4 depth=3" do
    test "mid sups show workers; workers are leaf stubs", %{peer: peer} do
      node = peer.node

      {:ok, %{tree: tree}, []} = Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

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

  describe "walk/4 depth=2 with expanded mid-sup pid" do
    test "expanded mid sup has its children loaded even though depth=0", %{peer: peer} do
      node = peer.node

      mid_sup_a_pid =
        :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])

      assert is_pid(mid_sup_a_pid)

      expanded = MapSet.new([mid_sup_a_pid])

      {status, %{tree: tree}, _errors} = Walker.walk(node, [:voyager_fixture], 2, expanded)

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

  describe "walk/4 labels" do
    test "registered processes are named by their registered_name; unregistered by pid",
         %{peer: peer} do
      node = peer.node

      {:ok, %{tree: tree}, []} = Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      app_node = tree[:voyager_fixture]
      [root_node] = app_node.children

      # The root supervisor is registered as its module.
      assert root_node.name == Voyager.Test.FixtureApp.RootSupervisor

      # Mid supervisors are registered too.
      mid_names = Enum.map(root_node.children, & &1.name)
      assert Voyager.Test.FixtureApp.MidSupA in mid_names
      assert Voyager.Test.FixtureApp.MidSupB in mid_names

      # Workers are not registered, so their label falls back to their pid.
      for mid_node <- root_node.children, worker_node <- mid_node.children do
        assert worker_node.name == worker_node.pid
      end
    end

    test "the app node is labeled by its (unregistered) application-master pid",
         %{peer: peer} do
      node = peer.node

      {:ok, %{tree: tree}, []} = Walker.walk(node, [:voyager_fixture], 2, MapSet.new())

      app_node = tree[:voyager_fixture]
      # The application master is not a registered process, so the app node's
      # label is its pid rather than the application atom.
      assert app_node.name == app_node.pid
      assert is_pid(app_node.name)
    end
  end

  describe "walk/4 relationships" do
    test "worker link to an external process yields a :link edge and a worker rel_node",
         %{peer: peer} do
      node = peer.node
      {_mid_a, [w1 | _]} = midsup_a_workers(node)

      target = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      :ok = :erpc.call(node, GenServer, :call, [w1, {:link, target}])

      {_status, %{relations: relations, rel_nodes: rel_nodes}, _errors} =
        Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      assert Enum.any?(relations, fn r ->
               r.from == w1 and r.to == target and r.kind == :link
             end)

      assert Enum.any?(rel_nodes, fn n -> n.id == target and n.type == :worker end)
    end

    test "monitor between two supervised workers yields :monitor and :monitored_by edges",
         %{peer: peer} do
      node = peer.node
      {_mid_a, [w1, w2]} = midsup_a_workers(node)

      _ref = :erpc.call(node, GenServer, :call, [w1, {:monitor, w2}])

      {_status, %{relations: relations}, _errors} =
        Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      assert Enum.any?(relations, fn r ->
               r.from == w1 and r.to == w2 and r.kind == :monitor
             end)

      assert Enum.any?(relations, fn r ->
               r.from == w2 and r.to == w1 and r.kind == :monitored_by
             end)
    end

    test "supervisor pid-links are not emitted as relationship edges", %{peer: peer} do
      node = peer.node
      {mid_a, _workers} = midsup_a_workers(node)

      {_status, %{relations: relations}, _errors} =
        Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      # A supervisor is linked to its parent and children, but those duplicate
      # the supervision spine and must not appear as :link edges.
      refute Enum.any?(relations, fn r ->
               r.from == mid_a and is_pid(r.to) and r.kind == :link
             end)
    end

    test "worker-owned port yields a :link edge and a port rel_node", %{peer: peer} do
      node = peer.node
      {_mid_a, [w1 | _]} = midsup_a_workers(node)

      port = :erpc.call(node, GenServer, :call, [w1, {:open_port, {:spawn, ~c"cat"}, []}])
      assert is_port(port)

      {_status, %{relations: relations, rel_nodes: rel_nodes}, _errors} =
        Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      assert Enum.any?(relations, fn r ->
               r.from == w1 and r.to == port and r.kind == :link
             end)

      assert Enum.any?(rel_nodes, fn n -> n.id == port and n.type == :port end)
    end
  end

  describe "walk/4 app not running" do
    test "returns partial with error for nonexistent app", %{peer: peer} do
      node = peer.node

      {:partial, %{tree: tree}, errors} =
        Walker.walk(node, [:nonexistent_app_xyz], 3, MapSet.new())

      assert tree == %{}
      assert [{:root_supervisor, :nonexistent_app_xyz, :not_running}] = errors
    end

    test "returns ok tree for running apps alongside error for nonexistent", %{peer: peer} do
      node = peer.node

      {:partial, %{tree: tree}, errors} =
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
