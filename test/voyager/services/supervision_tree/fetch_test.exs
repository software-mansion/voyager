defmodule Voyager.Services.SupervisionTree.FetchTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)
    on_exit(fn -> RemoteFixture.stop_peer!(peer) end)
    {:ok, peer: peer}
  end

  describe "start/1" do
    test "returns task with matching ref and delivers walk result", %{peer: peer} do
      task =
        Fetch.start(%{
          node: peer.node,
          apps: [:voyager_fixture],
          depth: 2,
          expanded: MapSet.new()
        })

      assert_receive {ref, {status, result, _errors}}, 2_000

      assert ref == task.ref
      assert status in [:ok, :partial]
      assert is_map(result.tree)
      assert Map.has_key?(result.tree, :voyager_fixture)
    end
  end

  describe "cancel/1" do
    test "terminates task and suppresses result message", %{peer: peer} do
      task =
        Fetch.start(%{
          node: peer.node,
          apps: [:voyager_fixture],
          depth: 2,
          expanded: MapSet.new()
        })

      :ok = Fetch.cancel(task)

      # No result message should arrive — demonitor flushed the DOWN, and
      # the task process was killed before it could deliver the result.
      ref = task.ref
      refute_receive {^ref, _}, 200
    end

    test "is safe to call after task has already finished", %{peer: peer} do
      task =
        Fetch.start(%{
          node: peer.node,
          apps: [:voyager_fixture],
          depth: 2,
          expanded: MapSet.new()
        })

      # Wait for the task to finish so it is no longer a supervisor child.
      assert_receive {ref, {_status, _result, _errors}}, 2_000
      assert ref == task.ref

      # Cancelling a finished task must not raise.
      assert :ok = Fetch.cancel(task)
    end

    test "task is not present in TaskSupervisor children after cancel", %{peer: peer} do
      task =
        Fetch.start(%{
          node: peer.node,
          apps: [:voyager_fixture],
          depth: 10,
          expanded: MapSet.new()
        })

      :ok = Fetch.cancel(task)

      # Sync: get_state forces processing of any pending supervisor messages.
      _ = :sys.get_state(Voyager.TaskSupervisor)

      children = Task.Supervisor.children(Voyager.TaskSupervisor)
      refute task.pid in children
    end
  end

  describe "async_nolink crash isolation" do
    test "killing the task pid delivers :DOWN to caller without crashing caller", %{peer: peer} do
      task =
        Fetch.start(%{
          node: peer.node,
          apps: [:voyager_fixture],
          depth: 2,
          expanded: MapSet.new()
        })

      Process.exit(task.pid, :kill)

      # async_nolink means we get a DOWN message, not a process crash.
      assert_receive {:DOWN, ref, :process, _pid, :killed}, 1_000
      assert ref == task.ref
    end
  end
end
