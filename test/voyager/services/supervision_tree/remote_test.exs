defmodule Voyager.Services.SupervisionTree.RemoteTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.SupervisionTree.Remote
  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)

    on_exit(fn ->
      try do
        RemoteFixture.stop_peer!(peer)
      catch
        :exit, :noproc -> :ok
        :exit, {:noproc, _} -> :ok
      end
    end)

    %{peer: peer, node: peer.node}
  end

  describe "list_applications/1" do
    test "returns ok with apps list and :voyager_fixture is included", %{node: node} do
      assert {:ok, apps} = Remote.list_applications(node)
      app_names = Enum.map(apps, fn {name, _desc, _vsn} -> name end)
      assert :voyager_fixture in app_names
    end
  end

  describe "which_children/2" do
    test "root supervisor has 2 mid-supervisor children", %{node: node} do
      {:ok, _, root_pid} = Remote.app_root_chain(node, :voyager_fixture)
      assert {:ok, children} = Remote.which_children(node, root_pid)
      assert length(children) == 2

      Enum.each(children, fn {_id, child_pid, type, _modules} ->
        assert is_pid(child_pid)
        assert type == :supervisor
      end)
    end
  end

  describe "process_info_batch/2" do
    test "returns map with memory and status for mid-supervisor pids", %{node: node} do
      {:ok, _, root_pid} = Remote.app_root_chain(node, :voyager_fixture)
      {:ok, children} = Remote.which_children(node, root_pid)
      mid_pids = Enum.map(children, fn {_id, pid, _type, _mods} -> pid end)

      assert {:ok, info_map} = Remote.process_info_batch(node, mid_pids)

      Enum.each(mid_pids, fn pid ->
        assert Map.has_key?(info_map, pid)
        pinfo = info_map[pid]
        assert is_map(pinfo)
        assert Map.has_key?(pinfo, :memory)
        assert Map.has_key?(pinfo, :status)
        # Relationship keys ride along on the same batch call.
        assert Map.has_key?(pinfo, :links)
        assert Map.has_key?(pinfo, :monitors)
        assert Map.has_key?(pinfo, :monitored_by)
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

  describe "ancestors/2" do
    test "returns the root supervisor's recorded ancestors", %{node: node} do
      {:ok, _, root_pid} = Remote.app_root_chain(node, :voyager_fixture)

      assert {:ok, ancestors} = Remote.ancestors(node, root_pid)
      assert is_list(ancestors)
      # The root supervisor was started by the application master.
      assert Enum.any?(ancestors, &is_pid/1)
    end
  end

  describe "disconnected node" do
    test "returns {:error, :not_connected} after peer is stopped", %{peer: peer, node: node} do
      RemoteFixture.stop_peer!(peer)

      assert {:error, :not_connected} = Remote.list_applications(node)
    end
  end
end
