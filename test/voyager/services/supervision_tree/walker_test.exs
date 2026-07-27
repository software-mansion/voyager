defmodule Voyager.Services.SupervisionTree.WalkerTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.SupervisionTree.Walker
  alias Voyager.Test.RemoteFixture

  setup_all do
    fixture_app = RemoteFixture.start_fixture_app!()
    prev_erpc = Application.get_env(:voyager, :erpc)

    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)

    on_exit(fn ->
      Application.stop(fixture_app)
      Application.put_env(:voyager, :erpc, prev_erpc)
    end)

    {:ok, node: Node.self()}
  end

  # The flat key for a pid / port, matching the walker's `id_key/1`.
  defp key(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp key(port) when is_port(port), do: "#{inspect(port)}"

  # Resolves a node's children into their full node maps via `children_keys`.
  defp children(nodes, node), do: Enum.map(node.children_keys, &Map.fetch!(nodes, &1))

  # Unwraps the `application_master -> p -> root_supervisor` root chain the
  # walker builds for `:voyager_fixture`, returning `{app_node, p_node, root_node}`.
  defp app_chain_nodes(nodes) do
    app_node = Map.fetch!(nodes, "app:voyager_fixture")
    [p_node] = children(nodes, app_node)
    [root_node] = children(nodes, p_node)
    {app_node, p_node, root_node}
  end

  # Returns `{mid_sup_a_pid, [worker_pids]}` for MidSupA on the peer node.
  defp midsup_a_workers(node) do
    mid_a = :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])
    children = :erpc.call(node, :supervisor, :which_children, [mid_a])
    pids = Enum.map(children, fn {_id, pid, _type, _mods} -> pid end)
    {mid_a, pids}
  end

  describe "walk/4 depth=3, no expanded" do
    test "root chain is application_master -> p -> root sup; mid sups are stubs",
         %{node: node} do
      {:ok, %{nodes: nodes}, []} = Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      assert Map.has_key?(nodes, "app:voyager_fixture")

      {app_node, p_node, root_node} = app_chain_nodes(nodes)

      # application_master node wraps the intermediate process `p`.
      assert app_node.type == :app
      assert app_node.child_count == 1

      # `p` is the root supervisor's $ancestor; its sole child is the root sup.
      assert p_node.type == :supervisor
      assert is_pid(p_node.pid)
      assert p_node.pid != app_node.pid
      assert p_node.pid != root_node.pid
      assert p_node.child_count == 1

      assert root_node.type == :supervisor
      assert is_list(root_node.children_keys)
      assert length(root_node.children_keys) == 2
      assert root_node.child_count == 2

      for mid_node <- children(nodes, root_node) do
        assert mid_node.type == :supervisor
        assert mid_node.children_keys == :not_loaded
        # stubbed via depth — count was fetched via count_children
        assert is_integer(mid_node.child_count)
        assert mid_node.child_count > 0
      end
    end
  end

  describe "walk/4 depth=4" do
    test "mid sups show workers; workers are leaf stubs", %{node: node} do
      {:ok, %{nodes: nodes}, []} = Walker.walk(node, [:voyager_fixture], 4, MapSet.new())

      {_app_node, _p_node, root_node} = app_chain_nodes(nodes)

      for mid_node <- children(nodes, root_node) do
        assert mid_node.type == :supervisor
        assert is_list(mid_node.children_keys)
        assert length(mid_node.children_keys) == 2

        for worker_node <- children(nodes, mid_node) do
          assert worker_node.type == :worker
          assert worker_node.children_keys == :not_loaded
          assert worker_node.child_count == 0
        end
      end
    end
  end

  describe "walk/4 depth=3 with expanded mid-sup pid" do
    test "expanded mid sup has its children loaded even though depth=0", %{node: node} do
      mid_sup_a_pid =
        :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])

      assert is_pid(mid_sup_a_pid)

      expanded = MapSet.new([mid_sup_a_pid])

      {status, %{nodes: nodes}, _errors} = Walker.walk(node, [:voyager_fixture], 3, expanded)

      assert status in [:ok, :partial]

      {_app_node, _p_node, root_node} = app_chain_nodes(nodes)

      mid_sup_a_node =
        Enum.find(children(nodes, root_node), fn child ->
          child.pid == mid_sup_a_pid
        end)

      refute is_nil(mid_sup_a_node)
      assert mid_sup_a_node.type == :supervisor
      # MidSupA was in expanded, so its children should be loaded
      assert is_list(mid_sup_a_node.children_keys)
      assert length(mid_sup_a_node.children_keys) == 2

      for worker_node <- children(nodes, mid_sup_a_node) do
        assert worker_node.type == :worker
      end
    end
  end

  describe "walk/4 labels" do
    test "registered processes are named by their registered_name; unregistered by pid",
         %{node: node} do
      {:ok, %{nodes: nodes}, []} = Walker.walk(node, [:voyager_fixture], 4, MapSet.new())

      {_app_node, _p_node, root_node} = app_chain_nodes(nodes)

      # The root supervisor is registered as its module.
      assert root_node.name == Voyager.Test.FixtureApp.RootSupervisor

      # Mid supervisors are registered too.
      mid_names = Enum.map(children(nodes, root_node), & &1.name)
      assert Voyager.Test.FixtureApp.MidSupA in mid_names
      assert Voyager.Test.FixtureApp.MidSupB in mid_names

      # Workers are not registered, so their label falls back to their pid.
      for mid_node <- children(nodes, root_node), worker_node <- children(nodes, mid_node) do
        assert worker_node.name == worker_node.pid
      end
    end

    test "the application-master and p nodes are labeled by their (unregistered) pids",
         %{node: node} do
      {:ok, %{nodes: nodes}, []} = Walker.walk(node, [:voyager_fixture], 3, MapSet.new())

      {app_node, p_node, _root_node} = app_chain_nodes(nodes)

      # Neither the application master nor `p` is a registered process, so each
      # falls back to its pid rather than to the application atom.
      assert app_node.name == app_node.pid
      assert is_pid(app_node.name)

      assert p_node.name == p_node.pid
      assert is_pid(p_node.name)
    end
  end

  describe "walk/5 relationships" do
    test "worker link to an external process yields a :link edge and a worker rel node",
         %{node: node} do
      {_mid_a, [w1 | _]} = midsup_a_workers(node)

      target = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])

      on_exit(fn ->
        :erpc.call(node, Process, :exit, [target, :kill])
        :erpc.call(node, :sys, :get_state, [Voyager.Test.FixtureApp.MidSupA])
      end)

      :ok = :erpc.call(node, GenServer, :call, [w1, {:link, target}])

      {_status, %{nodes: nodes, edges: edges}, _errors} =
        Walker.walk(node, [:voyager_fixture], 4, MapSet.new(), true)

      assert Enum.any?(Map.values(edges), fn e ->
               e.source == w1 and e.target == target and e.kind == :link
             end)

      assert nodes[key(target)].type == :worker
      assert nodes[key(target)].parent_key == nil
    end

    test "monitor between two supervised workers yields :monitor and :monitored_by edges",
         %{node: node} do
      {_mid_a, [w1, w2]} = midsup_a_workers(node)

      _ref = :erpc.call(node, GenServer, :call, [w1, {:monitor, w2}])

      {_status, %{edges: edges}, _errors} =
        Walker.walk(node, [:voyager_fixture], 4, MapSet.new(), true)

      assert Enum.any?(Map.values(edges), fn e ->
               e.source == w1 and e.target == w2 and e.kind == :monitor
             end)

      assert Enum.any?(Map.values(edges), fn e ->
               e.source == w2 and e.target == w1 and e.kind == :monitored_by
             end)
    end

    test "supervisor pid-links are not emitted as relationship edges", %{node: node} do
      {mid_a, _workers} = midsup_a_workers(node)

      {_status, %{edges: edges}, _errors} =
        Walker.walk(node, [:voyager_fixture], 4, MapSet.new(), true)

      # A supervisor is linked to its parent and children, but those duplicate
      # the supervision spine and must not appear as :link edges.
      refute Enum.any?(Map.values(edges), fn e ->
               e.source == mid_a and e.kind == :link and is_pid(e.target)
             end)
    end

    test "worker-owned port yields a :link edge and a port rel node", %{node: node} do
      {_mid_a, [w1 | _]} = midsup_a_workers(node)

      port = :erpc.call(node, GenServer, :call, [w1, {:open_port, {:spawn, ~c"cat"}, []}])
      assert is_port(port)

      on_exit(fn ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end
      end)

      {_status, %{nodes: nodes, edges: edges}, _errors} =
        Walker.walk(node, [:voyager_fixture], 4, MapSet.new(), true)

      assert Enum.any?(Map.values(edges), fn e ->
               e.source == w1 and e.target == port and e.kind == :link
             end)

      assert nodes[key(port)].type == :port
    end
  end

  describe "walk/4 app not running" do
    test "returns partial with error for nonexistent app", %{node: node} do
      {:partial, %{nodes: nodes}, errors} =
        Walker.walk(node, [:nonexistent_app_xyz], 4, MapSet.new())

      assert nodes == %{}
      assert [{:root_supervisor, :nonexistent_app_xyz, :not_running}] = errors
    end

    test "returns ok tree for running apps alongside error for nonexistent", %{node: node} do
      {:partial, %{nodes: nodes}, errors} =
        Walker.walk(node, [:voyager_fixture, :nonexistent_app_xyz], 2, MapSet.new())

      assert Map.has_key?(nodes, "app:voyager_fixture")
      refute Map.has_key?(nodes, "app:nonexistent_app_xyz")

      assert Enum.any?(errors, fn
               {:root_supervisor, :nonexistent_app_xyz, :not_running} -> true
               _ -> false
             end)
    end
  end
end
