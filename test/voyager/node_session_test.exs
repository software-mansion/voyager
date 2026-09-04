defmodule Voyager.NodeSessionTest do
  use Voyager.DataCase, async: false

  alias Voyager.NodeSession
  alias Voyager.NodeSession.Session

  @agent_module :voyager_agent

  defmodule FakeConnector do
    @moduledoc false
    @behaviour Voyager.NodeSession.Connector

    @impl true
    def name, do: :fake

    @impl true
    def connect(_node_name, _cookie, opts) do
      case Keyword.get(opts, :fail) do
        nil ->
          meta = %{test_pid: Keyword.fetch!(opts, :test_pid), ref: Keyword.get(opts, :ref)}
          {:ok, Keyword.get(opts, :node, Node.self()), meta}

        reason ->
          {:error, reason}
      end
    end

    @impl true
    def disconnect(node, meta) do
      send(meta.test_pid, {:connector_disconnect, node})
      :ok
    end

    @impl true
    def subscriptions, do: ["fake_connector_topic"]

    @impl true
    def teardown?({:fake_transport_down, ref}, %{ref: ref}), do: true
    def teardown?(_msg, _meta), do: false
  end

  setup do
    previous_state = :sys.get_state(NodeSession)
    previous_erpc = Application.get_env(:voyager, :erpc)
    # Connect now injects the agent, so the real transport has to run against this node.
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> previous_state end)
      Application.put_env(:voyager, :erpc, previous_erpc)
      stop_agent()
    end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    :ok
  end

  defp stop_agent do
    case Process.whereis(@agent_module) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    :code.purge(@agent_module)
    :code.delete(@agent_module)
    :code.purge(@agent_module)
    :ok
  end

  describe "connect_via/4" do
    test "establishes a session and broadcasts :node_connected" do
      assert :ok =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret",
                 test_pid: self()
               )

      node = Node.self()

      assert %Session{node: ^node, node_name: "demo@localhost", connector: FakeConnector} =
               NodeSession.current()

      assert NodeSession.connected?()
      assert_receive {:node_connected, ^node}
    end

    test "loads and registers the agent on the connected node" do
      assert :ok =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret",
                 test_pid: self()
               )

      assert Code.loaded?(@agent_module)
      assert is_pid(Process.whereis(@agent_module))
      assert :sys.get_state(@agent_module) == {:state, %{Node.self() => true}}
    end

    test "fails the connect and tears down the connector when the agent cannot be installed" do
      unreachable = :"voyager-nonexistent@nohost"

      assert {:error, {:agent_install_failed, :noconnection}} =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret",
                 test_pid: self(),
                 node: unreachable
               )

      assert_receive {:connector_disconnect, ^unreachable}
      refute NodeSession.connected?()
      refute_received {:node_connected, _}
    end

    test "rejects a second connect attempt while already connected" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      assert {:error, :already_connected} =
               NodeSession.connect_via(FakeConnector, "other@localhost", "secret",
                 test_pid: self()
               )

      assert NodeSession.current().node_name == "demo@localhost"
    end

    test "surfaces the connector's error without establishing a session" do
      assert {:error, :boom} =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", fail: :boom)

      refute NodeSession.connected?()
    end

    test "emits connect_failed telemetry with connector and reason on failure" do
      handler_id = "test-connect-failed-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :node, :connect_failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :boom} =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", fail: :boom)

      assert_receive {:telemetry, [:voyager, :node, :connect_failed], %{},
                      %{connected_via: :fake, reason: :boom}}
    end
  end

  describe "disconnect/0" do
    test "returns :not_connected when idle" do
      assert {:error, :not_connected} = NodeSession.disconnect()
    end

    test "tears down the connector and clears the session" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      node = Node.self()
      assert :ok = NodeSession.disconnect()

      assert_receive {:connector_disconnect, ^node}
      assert_receive {:node_disconnected, ^node}
      refute NodeSession.connected?()
      assert {:error, :not_connected} = NodeSession.disconnect()
    end
  end

  describe "remote node death" do
    test "tears down the connector, drops the session, and broadcasts :nodedown" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      node = Node.self()
      send(NodeSession, {:nodedown, node})

      assert_receive {:connector_disconnect, ^node}
      assert_receive {:nodedown, ^node}
      refute NodeSession.connected?()
    end
  end

  describe "agent_missing/1" do
    test "drops the session and broadcasts :node_disconnected" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      node = Node.self()
      NodeSession.agent_missing(node)

      assert_receive {:connector_disconnect, ^node}
      assert_receive {:node_disconnected, ^node}
      refute NodeSession.connected?()
    end

    test "ignores a node that is not the current session" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      NodeSession.agent_missing(:other@nohost)
      _ = :sys.get_state(NodeSession)

      assert NodeSession.connected?()
    end
  end

  describe "transport teardown" do
    test "drops the session without calling disconnect/2 when the connector signals teardown" do
      ref = make_ref()

      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret",
          test_pid: self(),
          ref: ref
        )

      node = Node.self()
      send(NodeSession, {:fake_transport_down, ref})

      assert_receive {:nodedown, ^node}
      refute_received {:connector_disconnect, _}
      refute NodeSession.connected?()
    end

    test "ignores messages the connector does not recognize as teardown" do
      :ok =
        NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", test_pid: self())

      send(NodeSession, :some_unrelated_message)
      _ = :sys.get_state(NodeSession)

      assert NodeSession.connected?()
    end
  end
end
