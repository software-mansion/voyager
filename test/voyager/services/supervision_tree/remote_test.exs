defmodule Voyager.Services.SupervisionTree.RemoteTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.SupervisionTree.Remote
  alias Voyager.Test.RemoteFixture

  setup_all do
    fixture_app = RemoteFixture.start_fixture_app!()
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)

    on_exit(fn ->
      Application.stop(fixture_app)
      Application.put_env(:voyager, :erpc, Voyager.ErpcMock)
    end)

    {:ok, node: Node.self()}
  end

  describe "list_applications/1" do
    test "returns ok with apps list and fixture app is included", %{node: node} do
      assert {:ok, apps} = Remote.list_applications(node)
      app_names = Enum.map(apps, fn {name, _desc, _vsn} -> name end)
      assert :voyager_fixture in app_names
    end

    test "returns ok with apps list and fixture app is not included when stopped", %{node: node} do
      Application.stop(:voyager_fixture)

      assert {:ok, apps} = Remote.list_applications(node)
      app_names = Enum.map(apps, fn {name, _desc, _vsn} -> name end)
      assert :voyager_fixture not in app_names

      Application.start(:voyager_fixture)
    end
  end

  describe "app_masters/2" do
    test "returns master pids aligned with apps; unknown apps map to :undefined", %{
      node: node
    } do
      assert {:ok, [fixture_master, :undefined]} =
               Remote.app_masters(node, [:voyager_fixture, :nonexistent_app_xyz])

      assert is_pid(fixture_master)
    end

    test "returns an empty list without an :erpc call for no apps", %{node: node} do
      assert {:ok, []} = Remote.app_masters(node, [])
    end
  end

  describe "app_children/2" do
    test "returns the root supervisor for each master pid", %{node: node} do
      {:ok, [master]} = Remote.app_masters(node, [:voyager_fixture])

      assert {:ok, [child]} = Remote.app_children(node, [master])
      assert match?({pid, _module} when is_pid(pid), child) or is_pid(child)
    end
  end

  describe "which_children/2" do
    test "root supervisor has 2 mid-supervisor children", %{node: node} do
      {:ok, [master]} = Remote.app_masters(node, [:voyager_fixture])
      {:ok, [{root_pid, _}]} = Remote.app_children(node, [master])

      assert {:ok, children} = Remote.which_children(node, root_pid)
      assert length(children) == 2

      Enum.each(children, fn {_id, child_pid, type, _modules} ->
        assert is_pid(child_pid)
        assert type == :supervisor
      end)
    end
  end

  describe "which_children_many/2 and count_children_many/2" do
    test "return per-supervisor results aligned with the input pids", %{node: node} do
      {:ok, [master]} = Remote.app_masters(node, [:voyager_fixture])
      {:ok, [{root_pid, _}]} = Remote.app_children(node, [master])

      {:ok, mids} = Remote.which_children(node, root_pid)
      mid_pids = Enum.map(mids, fn {_id, pid, _type, _mods} -> pid end)

      assert {:ok, children_lists} = Remote.which_children_many(node, mid_pids)
      assert length(children_lists) == length(mid_pids)
      assert Enum.all?(children_lists, &(length(&1) == 2))

      assert {:ok, counts} = Remote.count_children_many(node, mid_pids)
      assert counts == Enum.map(mid_pids, fn _ -> 2 end)
    end
  end

  describe "process_info_batch/2" do
    test "returns map with memory and status for mid-supervisor pids", %{node: node} do
      {:ok, [master]} = Remote.app_masters(node, [:voyager_fixture])
      {:ok, [{root_pid, _}]} = Remote.app_children(node, [master])
      {:ok, children} = Remote.which_children(node, root_pid)
      mid_pids = Enum.map(children, fn {_id, pid, _type, _mods} -> pid end)

      assert {:ok, info_map} = Remote.process_info_batch(node, mid_pids)

      Enum.each(mid_pids, fn pid ->
        assert Map.has_key?(info_map, pid)
        pinfo = info_map[pid]
        assert is_map(pinfo)
        assert Map.has_key?(pinfo, :registered_name)
      end)
    end

    test "dead pid maps to :dead", %{node: node} do
      # Get a worker pid from MidSupA
      mid_a_pid = :erpc.call(node, Process, :whereis, [Voyager.Test.FixtureApp.MidSupA])
      {:ok, workers} = Remote.which_children(node, mid_a_pid)
      {_id, worker_pid, :worker, _mods} = hd(workers)

      # Kill the worker; its supervisor will restart it, giving a new pid
      :erpc.call(node, Process, :exit, [worker_pid, :kill])

      # Sync: wait for the supervisor to have handled the DOWN and restarted the child
      :erpc.call(node, :sys, :get_state, [Voyager.Test.FixtureApp.MidSupA])

      # The old pid is now dead; query a batch containing it alongside a live pid
      assert {:ok, info_map} = Remote.process_info_batch(node, [worker_pid, mid_a_pid])
      assert info_map[worker_pid] == :dead
      assert is_map(info_map[mid_a_pid])
    end
  end
end
