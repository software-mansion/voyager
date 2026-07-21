defmodule Voyager.NodeSessionTest do
  use ExUnit.Case, async: false

  alias Voyager.Fakes
  alias Voyager.NodeSession

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> previous_state end)
    end)

    :ok
  end

  describe "disconnect/0" do
    test "returns :not_connected when no session is active" do
      assert {:error, :not_connected} = NodeSession.disconnect()
    end

    test "clears a faked session without requiring Node.alive?" do
      session = Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())

      assert :ok = NodeSession.disconnect()
      assert NodeSession.current() == nil
      assert_receive {:node_disconnected, node}
      assert node == session.node
    end
  end
end
