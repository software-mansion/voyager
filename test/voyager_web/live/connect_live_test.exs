defmodule VoyagerWeb.ConnectLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes

  setup do
    previous_state = :sys.get_state(Voyager.NodeSession)
    Fakes.put_session(nil)

    on_exit(fn ->
      :sys.replace_state(Voyager.NodeSession, fn _ -> previous_state end)
    end)

    :ok
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

      tip_html = view |> element("#mode-toggle-tip-portal") |> render()
      assert tip_html =~ "<strong>proxy_epmd</strong>"
      assert tip_html =~ "module is not active"
    end

    test "disabled with a connected tooltip when a node session is active", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "input#mode-direct[disabled]")

      tip_html = view |> element("#mode-toggle-tip-portal") |> render()
      assert tip_html =~ "Cannot change mode while connected"
      refute tip_html =~ "proxy_epmd"
    end

    test "disabled with a connecting tooltip while an SSH connection attempt is in progress", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:ssh_connecting, true})
      _ = :sys.get_state(view.pid)

      tip_html = view |> element("#mode-toggle-tip-portal") |> render()
      assert tip_html =~ "Cannot change mode while connecting"
    end
  end
end
