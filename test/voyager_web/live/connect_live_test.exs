defmodule VoyagerWeb.ConnectLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.ProxyEpmd
  alias Voyager.Settings

  setup do
    previous_state = :sys.get_state(NodeSession)

    :sys.replace_state(NodeSession, fn state ->
      state
      |> Map.put(:session, nil)
      |> Map.put(:last_via, nil)
    end)

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
      assert has_element?(view, ~s|#direct-connect-btn[disabled]|)
      assert has_element?(view, ~s|[data-testid="fill-recent-btn"][disabled]|)

      view |> element("#disconnect-from-connect") |> render_click()

      assert has_element?(view, "#flash-info", "Node disconnected: demo@localhost")
      refute has_element?(view, "#disconnect-from-connect")
      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#direct-connect-btn:not([disabled])|)
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
      assert has_element?(view, ~s|#direct-connect-btn:not([disabled])|)
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
    end
  end

  describe "settings link" do
    test "links to the settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#open-settings[href="/settings?return_to=%2F"]|)
    end
  end

  describe "mode toggle" do
    test "disabled with a proxy_epmd tooltip when the proxy epmd module is not active", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[disabled]")
      assert has_element?(view, "input#mode-ssh[disabled]")

      tip_html = view |> element("#mode-toggle-tip-proxy_epmd_inactive-portal") |> render()
      assert tip_html =~ "<strong>proxy_epmd</strong>"
      assert tip_html =~ "module is not active"
    end

    test "disabled with a connected tooltip when a node session is active", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[disabled]")

      tip_html = view |> element("#mode-toggle-tip-connected-portal") |> render()
      assert tip_html =~ "Cannot change mode while connected"
      refute tip_html =~ "proxy_epmd"
    end

    test "updates the tooltip after disconnecting, instead of keeping the stale reason", %{
      conn: conn
    } do
      Fakes.connect_node!(Fakes.node_session())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[disabled]")
      tip_html = view |> element("#mode-toggle-tip-connected-portal") |> render()
      assert tip_html =~ "Cannot change mode while connected"

      view |> element("#disconnect-from-connect") |> render_click()

      assert NodeSession.current() == nil

      assert has_element?(view, "input#mode-direct[disabled]")
      refute has_element?(view, "#mode-toggle-tip-connected-portal")

      tip_html = view |> element("#mode-toggle-tip-proxy_epmd_inactive-portal") |> render()
      assert tip_html =~ "<strong>proxy_epmd</strong>"
      refute tip_html =~ "Cannot change mode while connected"
    end
  end

  describe "connection mode" do
    setup :enable_proxy_epmd

    test "selects Direct while connected via distribution", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[checked]")
      refute has_element?(view, "input#mode-ssh[checked]")
      assert has_element?(view, ~s|#direct-connect-btn[disabled]|)
    end

    test "selects SSH Tunnel while connected via SSH", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, "#ssh-connect-form")
      assert has_element?(view, ~s|#ssh-connect-btn[disabled]|)
      assert has_element?(view, "input#mode-ssh[disabled]")

      tip_html = view |> element("#mode-toggle-tip-connected-portal") |> render()
      assert tip_html =~ "Cannot change mode while connected"
    end

    test "keeps SSH selected and re-enables the form after disconnect", %{conn: conn} do
      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      Fakes.put_session(nil)
      broadcast(NodeSession.topic(), {:node_disconnected, session.node})

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)
      refute has_element?(view, "input#mode-ssh[disabled]")
    end

    test "keeps SSH selected after nodedown", %{conn: conn} do
      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      broadcast(NodeSession.topic(), {:nodedown, session.node})

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)
    end

    test "selects SSH on remount after the SSH session has been cleared", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(connector: SshConnector))
      Fakes.put_session(nil)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)
    end
  end

  describe "onboarding popup" do
    setup do
      # test.exs locks :terms_accepted so unrelated LiveViews skip the modal.
      # Clear it here so we exercise the real first-launch / DB-backed path.
      Application.delete_env(:voyager, :terms_accepted)
      on_exit(fn -> Application.put_env(:voyager, :terms_accepted, true) end)
      :ok
    end

    test "shows on first launch and dismissing it persists acceptance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#onboarding-modal")
      refute Settings.get(:terms_accepted, false)

      view |> element("#onboarding-continue") |> render_click()

      refute has_element?(view, "#onboarding-modal")
      assert Settings.get(:terms_accepted, false)
      assert Voyager.Telemetry.enabled?()
    end

    test "does not show once terms have been accepted", %{conn: conn} do
      {:ok, _} = Voyager.Telemetry.accept_terms()

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#onboarding-modal")
    end
  end

  defp broadcast(pubsub_topic, event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, pubsub_topic, event)
  end

  defp enable_proxy_epmd(_context) do
    previous_epmd_module = :persistent_term.get(:voyager_epmd_module, :erl_epmd)
    :persistent_term.put(:voyager_epmd_module, ProxyEpmd)

    on_exit(fn -> :persistent_term.put(:voyager_epmd_module, previous_epmd_module) end)

    :ok
  end
end
