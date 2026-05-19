defmodule Voyager.Test.RemoteFixtureTest do
  use ExUnit.Case, async: false

  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)

    on_exit(fn -> RemoteFixture.stop_peer!(peer) end)

    {:ok, peer: peer}
  end

  test "root supervisor is running on peer node", %{peer: %{node: node}} do
    pid = :erpc.call(node, Process, :whereis, [Voyager.Test.FixtureApp.RootSupervisor])
    assert is_pid(pid), "Expected a pid, got: #{inspect(pid)}"
  end

  test "root supervisor has exactly 2 children", %{peer: %{node: node}} do
    children =
      :erpc.call(node, :supervisor, :which_children, [Voyager.Test.FixtureApp.RootSupervisor])

    assert length(children) == 2
  end

  test "each mid supervisor has exactly 2 worker children", %{peer: %{node: node}} do
    children_a =
      :erpc.call(node, :supervisor, :which_children, [Voyager.Test.FixtureApp.MidSupA])

    children_b =
      :erpc.call(node, :supervisor, :which_children, [Voyager.Test.FixtureApp.MidSupB])

    assert length(children_a) == 2
    assert length(children_b) == 2
  end

  test "all child processes are alive on the peer", %{peer: %{node: node}} do
    children =
      :erpc.call(node, :supervisor, :which_children, [Voyager.Test.FixtureApp.RootSupervisor])

    for {_id, pid, _type, _modules} <- children do
      assert :erpc.call(node, Process, :alive?, [pid])
    end
  end

  test "kill_supervisor!/2 kills the named supervisor", %{peer: %{node: node} = peer} do
    pid_before = :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])
    assert is_pid(pid_before)

    RemoteFixture.kill_supervisor!(peer, Voyager.Test.FixtureApp.MidSupA)

    # Wait for restart: the root supervisor will restart MidSupA.
    # Sync via :sys.get_state on RootSupervisor which processes messages in order.
    :erpc.call(node, :sys, :get_state, [Voyager.Test.FixtureApp.RootSupervisor])

    pid_after = :erpc.call(node, :erlang, :whereis, [Voyager.Test.FixtureApp.MidSupA])
    assert is_pid(pid_after)
    # The supervisor should have been restarted with a new pid
    assert pid_after != pid_before
  end
end
