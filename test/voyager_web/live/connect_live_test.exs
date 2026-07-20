defmodule VoyagerWeb.ConnectLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.Services.Distribution

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> previous_state end)
    end)

    :ok
  end

  describe "disconnect" do
    test "clears the connected indicator and re-enables the form", %{conn: conn} do
      assert :ok = Distribution.ensure_distributed(:longnames)
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#disconnect-from-connect")
      assert has_element?(view, "#connected-indicator", "demo@localhost")
      assert has_element?(view, ~s|#connect-btn[disabled]|)

      view |> element("#disconnect-from-connect") |> render_click()

      refute has_element?(view, "#disconnect-from-connect")
      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#connect-btn:not([disabled])|)
      assert NodeSession.current() == nil
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

      # Bypass the disabled button to exercise the server-side guard.
      render_click(view, "fill_recent", %{"id" => Integer.to_string(recent.id)})

      refute has_element?(view, ~s|#conn_node_name[value="#{recent.node_name}"]|)
  describe "settings link" do
    test "links to the settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#open-settings[href="/settings?return_to=%2F"]|)
    end
  end
end
