defmodule VoyagerWeb.ConnectLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Actions.Connections, as: ConnectionActions
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

  describe "disconnect" do
    test "clears the connected indicator, shows flash, and re-enables the form", %{conn: conn} do
      {:ok, _recent} =
        ConnectionActions.upsert_connected("recent@127.0.0.1", cookie: "secret")

      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#disconnect-from-connect")
      assert has_element?(view, "#connected-indicator", "demo@localhost")
      assert has_element?(view, ~s|#connect-btn[disabled]|)
      assert has_element?(view, ~s|[data-testid="fill-recent-btn"][disabled]|)

      view |> element("#disconnect-from-connect") |> render_click()

      assert has_element?(view, "#flash-info", "Node disconnected: demo@localhost")
      refute has_element?(view, "#disconnect-from-connect")
      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#connect-btn:not([disabled])|)
      assert has_element?(view, ~s|[data-testid="fill-recent-btn"]:not([disabled])|)
      assert NodeSession.current() == nil
    end

    test "shows nodedown flash and clears the connected UI via PubSub", %{conn: conn} do
      {:ok, _recent} =
        ConnectionActions.upsert_connected("recent@127.0.0.1", cookie: "secret")

      session = Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#connected-indicator", "demo@localhost")

      broadcast(NodeSession.topic(), {:nodedown, session.node})

      assert has_element?(view, "#flash-error", "Node down: demo@localhost")
      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#connect-btn:not([disabled])|)
      assert has_element?(view, ~s|[data-testid="fill-recent-btn"]:not([disabled])|)
    end
  end

  describe "fill_recent while connected" do
    test "does not fill the form when a session is active", %{conn: conn} do
      {:ok, recent} =
        ConnectionActions.upsert_connected("recent@127.0.0.1", cookie: "secret")

      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|[data-testid="fill-recent-btn"][disabled]|)
      refute has_element?(view, ~s|#conn_node_name[value="#{recent.node_name}"]|)
      refute has_element?(view, ~s|#conn_node_name[value="#{recent.node_name}"]|)
    end
  end

  describe "settings link" do
    test "links to the settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#open-settings[href="/settings?return_to=%2F"]|)
    end
  end

  defp broadcast(pubsub_topic, event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, pubsub_topic, event)
  end
end
