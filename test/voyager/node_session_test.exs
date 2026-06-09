defmodule Voyager.NodeSessionTest do
  use ExUnit.Case, async: false

  alias Voyager.NodeSession
  alias Voyager.NodeSession.Session

  @moduletag capture_log: true

  @fake_node :fake@localhost

  setup do
    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    :sys.replace_state(NodeSession, fn _ -> %{session: nil} end)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> %{session: nil} end)
    end)

    :ok
  end

  describe "when not connected" do
    test "current/0 returns nil" do
      assert NodeSession.current() == nil
    end

    test "connected?/0 returns false" do
      refute NodeSession.connected?()
    end

    test "disconnect/0 returns :not_connected" do
      assert {:error, :not_connected} = NodeSession.disconnect()
    end
  end

  describe "when connected (injected state)" do
    setup do
      session = %Session{
        node: @fake_node,
        node_name: "fake@localhost",
        cookie: "test-cookie",
        connected_at: DateTime.utc_now()
      }

      :sys.replace_state(NodeSession, fn _ -> %{session: session} end)
      {:ok, session: session}
    end

    test "connected?/0 returns true" do
      assert NodeSession.connected?()
    end

    test "current/0 returns the active session", %{session: session} do
      result = NodeSession.current()

      assert result.node == session.node
      assert result.node_name == session.node_name
      assert result.cookie == session.cookie
    end

    test "connect/3 returns :already_connected" do
      assert {:error, :already_connected} = NodeSession.connect("any@host", "cookie")
    end

    test "disconnect/0 clears the session" do
      :ok = NodeSession.disconnect()

      assert NodeSession.current() == nil
      refute NodeSession.connected?()
    end

    test "disconnect/0 broadcasts :node_disconnected" do
      NodeSession.disconnect()

      assert_receive {:node_disconnected, @fake_node}
    end

    test ":nodedown for the active node clears the session" do
      send(NodeSession, {:nodedown, @fake_node})
      _ = :sys.get_state(NodeSession)

      assert NodeSession.current() == nil
      refute NodeSession.connected?()
    end

    test ":nodedown for the active node broadcasts the event" do
      send(NodeSession, {:nodedown, @fake_node})

      assert_receive {:nodedown, @fake_node}
    end

    test ":nodedown for a different node does not clear the session" do
      send(NodeSession, {:nodedown, :other@localhost})
      _ = :sys.get_state(NodeSession)

      assert NodeSession.connected?()
    end
  end
end
