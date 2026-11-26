defmodule Voyager.Services.DemoNodeTest do
  # async: false because the test swaps out the app's registered DemoNode.
  use Voyager.DataCase, async: false

  import Voyager.TestUtils

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.NodeSession
  alias Voyager.Services.DemoNode

  @node :"voyager_demo@127.0.0.1"

  setup do
    events =
      for event <- [:start, :start_failed, :connect, :stop, :dismiss],
          do: [:voyager, :demo, event]

    handler = {__MODULE__, self()}
    :telemetry.attach_many(handler, events, &__MODULE__.forward_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @tag :capture_log
  test "returns an error without restarting when the demo node fails to boot" do
    pid = start_demo_node!(exec: {~c"/usr/bin/false", []})

    assert {:error, _reason} = DemoNode.start()
    assert Process.whereis(DemoNode) == pid

    assert_receive {:telemetry, [:voyager, :demo, :start_failed], %{duration_ms: _},
                    %{reason: :boot_failed}}
  end

  test "stays offered without saved connections, even once dismissed" do
    start_demo_node!()
    assert DemoNode.offer() == :sticky

    :ok = DemoNode.dismiss()

    assert DemoNode.offer() == :sticky
  end

  test "is dismissible with a saved direct connection and hidden once dismissed" do
    start_demo_node!()
    {:ok, _connection} = ConnectionActions.upsert_connected("app@127.0.0.1")
    assert DemoNode.offer() == :dismissible

    :ok = DemoNode.dismiss()

    assert DemoNode.offer() == :hidden
    assert_receive {:telemetry, [:voyager, :demo, :dismiss], _, _}
  end

  test "is dismissible with only a saved SSH connection" do
    start_demo_node!()
    {:ok, _connection} = SshConnectionActions.upsert_connected("deploy", "gw", 22, "app@gw")

    assert DemoNode.offer() == :dismissible
  end

  test "does not dismiss when the setting is locked" do
    previous = Application.fetch_env(:voyager, :demo_dismissed)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:voyager, :demo_dismissed, value)
        :error -> Application.delete_env(:voyager, :demo_dismissed)
      end
    end)

    start_demo_node!()
    Application.put_env(:voyager, :demo_dismissed, false)

    assert DemoNode.dismiss() == {:error, :locked}
    refute_received {:telemetry, [:voyager, :demo, :dismiss], _, _}
  end

  test "boots a loopback-only demo node with the given cookie and the demo tree" do
    start_demo_node!()

    assert {:ok, %{node_name: "voyager_demo@127.0.0.1", cookie: cookie}} = DemoNode.start()
    assert cookie =~ ~r/^[A-Z2-7]{52}$/
    assert_receive {:telemetry, [:voyager, :demo, :start], %{duration_ms: _}, _}

    peer = demo_peer()
    assert :peer.call(peer, :erlang, :node, []) == @node
    assert :peer.call(peer, :erlang, :get_cookie, []) == String.to_atom(cookie)

    assert :peer.call(peer, :application, :get_env, [:kernel, :inet_dist_use_interface]) ==
             {:ok, {127, 0, 0, 1}}

    apps = :peer.call(peer, :application, :which_applications, [])
    assert List.keymember?(apps, :supervision_tree_demo, 0)
    assert is_pid(:peer.call(peer, Process, :whereis, [SupervisionTreeDemo.Supervisor]))
    assert is_reference(:peer.call(peer, :ets, :whereis, [:kv_set]))
  end

  test "a second start replaces the running node with a new cookie" do
    start_demo_node!()
    {:ok, %{cookie: first_cookie}} = DemoNode.start()
    first_ref = Process.monitor(demo_peer())

    {:ok, %{cookie: second_cookie}} = DemoNode.start()

    assert_receive {:DOWN, ^first_ref, :process, _pid, _reason}
    assert second_cookie != first_cookie
    assert is_pid(demo_peer())

    assert_receive {:telemetry, [:voyager, :demo, :stop], %{duration_ms: _},
                    %{reason: :restarted}}
  end

  for event <- [:node_disconnected, :nodedown] do
    test "stops on #{event} of the demo node" do
      start_demo_node!()
      {:ok, _params} = DemoNode.start()
      ref = Process.monitor(demo_peer())

      broadcast({unquote(event), @node, nil})

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
      assert demo_peer() == nil
      assert_receive {:telemetry, [:voyager, :demo, :stop], _, %{reason: unquote(event)}}
    end
  end

  test "keeps running when another node disconnects" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    peer = demo_peer()

    broadcast({:node_disconnected, :"other@127.0.0.1", nil})

    assert demo_peer() == peer
  end

  test "stops when the user connects to another node" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    ref = Process.monitor(demo_peer())

    broadcast({:node_connected, :"other@127.0.0.1"})

    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert demo_peer() == nil
    assert_receive {:telemetry, [:voyager, :demo, :stop], _, %{reason: :other_node}}
  end

  test "stops when nobody connects within the idle timeout" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    peer = demo_peer()
    assert is_pid(peer)
    ref = Process.monitor(peer)

    send(DemoNode, {:timeout, :sys.get_state(DemoNode).timer, :idle_timeout})

    assert_receive {:DOWN, ^ref, :process, ^peer, _reason}
    assert demo_peer() == nil
    assert_receive {:telemetry, [:voyager, :demo, :stop], _, %{reason: :idle_timeout}}
    refute_received {:telemetry, [:voyager, :demo, :connect], _, _}
  end

  test "reports whether it runs and broadcasts when it starts and stops" do
    start_demo_node!()
    Phoenix.PubSub.subscribe(Voyager.PubSub, DemoNode.topic())
    refute DemoNode.running?()

    {:ok, _params} = DemoNode.start()
    assert_receive :demo_started
    assert DemoNode.running?()

    send(DemoNode, {:timeout, :sys.get_state(DemoNode).timer, :idle_timeout})

    assert_receive {:demo_stopped, :idle_timeout}
    refute DemoNode.running?()
  end

  test "connecting to the demo node cancels the idle timeout" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    %{timer: timer, peer: peer} = :sys.get_state(DemoNode)
    assert is_reference(timer)

    broadcast({:node_connected, @node})
    send(DemoNode, {:timeout, timer, :idle_timeout})

    assert %{timer: nil, peer: ^peer} = :sys.get_state(DemoNode)
    assert is_pid(peer)
    assert_receive {:telemetry, [:voyager, :demo, :connect], %{time_to_connect_ms: _}, _}
  end

  test "clears its state when the demo node halts" do
    start_demo_node!()
    {:ok, _params} = DemoNode.start()
    peer = demo_peer()
    ref = Process.monitor(peer)

    :peer.cast(peer, :erlang, :halt, [])

    assert_receive {:DOWN, ^ref, :process, ^peer, _reason}
    assert demo_peer() == nil
    assert_receive {:telemetry, [:voyager, :demo, :stop], _, %{reason: :halted}}
  end

  def forward_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp demo_peer, do: :sys.get_state(DemoNode).peer

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, NodeSession.topic(), event)
  end
end
