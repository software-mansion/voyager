defmodule VoyagerWeb.ConnectLiveSshAgentTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.Fakes
  alias Voyager.NodeSession

  @socket_path "~/.1password/agent.sock"

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  defp change_auth(view, params) do
    view |> element("#ssh-connect-form") |> render_change(%{"ssh" => params})
  end

  test "shows the agent socket field only for SSH agent auth", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    refute has_element?(view, "#ssh-agent-socket.hidden")

    for auth_method <- ["password", "key"] do
      change_auth(view, %{"auth_method" => auth_method})
      assert has_element?(view, "#ssh-agent-socket.hidden")
    end
  end

  test "keeps the agent socket when switching auth method", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    change_auth(view, %{"auth_method" => "agent", "agent_socket_path" => @socket_path})

    for auth_method <- ["password", "agent"] do
      change_auth(view, %{"auth_method" => auth_method})
    end

    assert has_element?(view, ~s|#ssh_agent_socket_path[value="#{@socket_path}"]|)
  end

  test "filling a recent connection restores the agent socket and opens Advanced", %{conn: conn} do
    SshConnectionActions.upsert_connected("deploy", "gw", 22, "demo@localhost",
      agent_socket_path: @socket_path
    )

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    assert has_element?(view, "#ssh-advanced.hidden")

    view |> element("[data-testid='fill-ssh-recent-btn']") |> render_click()

    assert has_element?(view, ~s|#ssh_agent_socket_path[value="#{@socket_path}"]|)
    refute has_element?(view, "#ssh-advanced.hidden")
  end

  test "filling a recent key connection keeps Advanced closed despite a saved socket", %{
    conn: conn
  } do
    SshConnectionActions.upsert_connected("deploy", "gw", 22, "demo@localhost",
      agent_socket_path: @socket_path
    )

    SshConnectionActions.upsert_connected("deploy", "gw", 22, "demo@localhost",
      auth_method: :key,
      key_path: "~/.ssh/id_ed25519"
    )

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    view |> element("[data-testid='fill-ssh-recent-btn']") |> render_click()

    assert has_element?(view, "#ssh-advanced.hidden")
  end
end
