defmodule VoyagerWeb.ConnectLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.TestUtils

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Settings

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

      broadcast(NodeSession.topic(), {:nodedown, session.node, nil})

      assert has_element?(view, "#flash-error", "Node down: demo@localhost")
      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#direct-connect-btn:not([disabled])|)
      assert has_element?(view, ~s|[data-testid="fill-recent-btn"]:not([disabled])|)
    end

    test "explains nodedown reasons", %{conn: conn} do
      session = Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      for {reason, message} <- [
            {:net_tick_timeout, "connection timed out, check your network"},
            {:send_net_tick_failed, "connection timed out, check your network"},
            {:shutdown, "connection lost"}
          ] do
        broadcast(NodeSession.topic(), {:nodedown, session.node, reason})

        assert has_element?(view, "#flash-error", "Node down: demo@localhost — #{message}")
      end

      refute has_element?(view, "#connected-indicator")
    end
  end

  describe "connect status" do
    test "disables the form while connecting and flashes a failure started elsewhere", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:node_connecting, "demo@localhost"})
      assert has_element?(view, ~s|#direct-connect-btn[disabled]|)

      send(view.pid, {:node_connect_failed, "demo@localhost", :bad_cookie})
      assert has_element?(view, ~s|#direct-connect-btn:not([disabled])|)
      assert has_element?(view, "#flash-error", "Authentication failed")
    end

    test "shows the failure on the form that started the connect", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

      view
      |> element("#ssh-connect-form")
      |> render_submit(%{
        "ssh" => %{
          "ssh_user" => "deploy",
          "ssh_host" => "gw",
          "node_name" => "demo@localhost",
          "cookie" => "secret"
        }
      })

      render_async(view)

      assert has_element?(view, "#ssh_node_name.input-error")
    end
  end

  describe "pre-filled from an agent request" do
    setup :enable_proxy_epmd

    test "fills a saved direct connection, cookie included", %{conn: conn} do
      {:ok, saved} = ConnectionActions.upsert_connected("shop@10.0.4.12", cookie: "secret")

      {:ok, view, _html} = live(conn, ~p"/?#{[connection: saved.id]}")

      assert has_element?(view, "#mcp-connect-request")
      assert has_element?(view, ~s|#conn_node_name[value="shop@10.0.4.12"]|)
      assert has_element?(view, ~s|#conn_cookie[value="secret"]|)
    end

    test "fills a saved SSH connection", %{conn: conn} do
      {:ok, saved} =
        SshConnectionActions.upsert_connected("deploy", "gw", 22, "app@127.0.0.1",
          cookie: "secret"
        )

      {:ok, view, _html} = live(conn, ~p"/?#{[mode: "ssh", connection: saved.id]}")

      assert has_element?(view, "#mcp-connect-request")
      assert has_element?(view, ~s|#ssh_node_name[value="app@127.0.0.1"]|)
      assert has_element?(view, ~s|#ssh_ssh_host[value="gw"]|)
    end

    test "fills the non-secret fields of a node that is not saved", %{conn: conn} do
      query = [mode: "ssh", node_name: "app@10.0.0.5", ssh_user: "deploy", ssh_host: "gw"]

      {:ok, view, _html} = live(conn, ~p"/?#{query}")

      assert has_element?(view, ~s|#ssh_node_name[value="app@10.0.0.5"]|)
      assert has_element?(view, ~s|#ssh_ssh_user[value="deploy"]|)
      refute has_element?(view, ~s|#ssh_cookie[value]:not([value=""])|)
    end

    test "shows no banner without a request", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#mcp-connect-request")
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

      assert has_element?(view, ~s|a#open-settings[href="/settings"]|)
    end

    test "falls back to Direct mode when proxy_epmd is inactive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

      assert has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|a#open-settings[href="/settings"]|)
    end

    test "falls back to Direct mode on an unknown mode query param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=garbage")

      assert has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|a#open-settings[href="/settings"]|)
    end

    test "links to the connection tutorial", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#connect-tutorial-link[href$="docs/connecting_to_a_node.md"]|)
    end

    test "grays out the tutorial link while an SSH connection is in progress", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a#connect-tutorial-link.text-primary")

      send(view.pid, {:node_connecting, "demo@localhost"})

      assert has_element?(view, ~s|a#connect-tutorial-link[class~="text-base-content/50"]|)
      refute has_element?(view, "a#connect-tutorial-link.text-primary")
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

    test "selects SSH Tunnel while connected via SSH and patches the URL", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               ~s|a#open-settings[href="/settings"]|
             )

      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, "#ssh-connect-form")
      assert has_element?(view, ~s|#ssh-connect-btn[disabled]|)
      assert has_element?(view, "input#mode-ssh[disabled]")

      tip_html = view |> element("#mode-toggle-tip-connected-portal") |> render()
      assert tip_html =~ "Cannot change mode while connected"
    end

    test "selects SSH and patches the URL when a session connects while idle on Direct", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[checked]")

      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))
      broadcast(NodeSession.topic(), {:node_connected, session.node})

      assert_patch(view, "/?mode=ssh")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, "#ssh-connect-form")
      assert has_element?(view, ~s|#ssh-connect-btn[disabled]|)
      assert has_element?(view, "input#mode-ssh[disabled]")
    end

    test "keeps SSH selected when a session connects while already on SSH", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

      assert has_element?(view, "input#mode-ssh[checked]")

      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))
      broadcast(NodeSession.topic(), {:node_connected, session.node})

      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, "#connected-indicator")
      assert has_element?(view, ~s|#ssh-connect-btn[disabled]|)
      assert has_element?(view, "input#mode-ssh[disabled]")
    end

    test "patches between Direct and SSH from the mode toggle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#mode-toggle") |> render_change(%{"mode" => "ssh"})

      assert_patch(view, "/?mode=ssh")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")

      view |> element("#mode-toggle") |> render_change(%{"mode" => "direct"})

      assert_patch(view, "/")
      assert has_element?(view, "input#mode-direct[checked]")
      refute has_element?(view, "input#mode-ssh[checked]")
    end

    test "keeps SSH selected and re-enables the form after disconnect", %{conn: conn} do
      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      Fakes.put_session(nil)
      broadcast(NodeSession.topic(), {:node_disconnected, session.node, nil})

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)
      refute has_element?(view, "input#mode-ssh[disabled]")
    end

    test "keeps SSH selected after nodedown", %{conn: conn} do
      session = Fakes.connect_node!(Fakes.node_session(connector: SshConnector))

      {:ok, view, _html} = live(conn, ~p"/")

      broadcast(NodeSession.topic(), {:nodedown, session.node, nil})

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)
    end

    test "selects SSH from the mode query param while disconnected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

      refute has_element?(view, "#connected-indicator")
      assert has_element?(view, "input#mode-ssh[checked]")
      refute has_element?(view, "input#mode-direct[checked]")
      assert has_element?(view, ~s|#ssh-connect-btn:not([disabled])|)

      assert has_element?(
               view,
               ~s|a#open-settings[href="/settings"]|
             )
    end

    test "stays on Direct after switching away from SSH and remounting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

      view |> element("#mode-toggle") |> render_change(%{"mode" => "direct"})
      assert_patch(view, "/")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[checked]")
      refute has_element?(view, "input#mode-ssh[checked]")
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
end
