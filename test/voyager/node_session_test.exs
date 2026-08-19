defmodule Voyager.NodeSessionTest do
  use Voyager.DataCase, async: false

  alias Voyager.NodeSession
  alias Voyager.NodeSession.Session

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
          {:ok, Node.self(), meta}

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
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
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
      assert NodeSession.last_via() == :fake
      assert_receive {:node_connected, ^node}
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
      previous_via = NodeSession.last_via()

      assert {:error, :boom} =
               NodeSession.connect_via(FakeConnector, "demo@localhost", "secret", fail: :boom)

      refute NodeSession.connected?()
      assert NodeSession.last_via() == previous_via
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
      assert NodeSession.last_via() == :fake
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
      assert NodeSession.last_via() == :fake
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
      assert NodeSession.last_via() == :fake
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
