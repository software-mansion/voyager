defmodule VoyagerWeb.ConnectLiveSshTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  describe "mode toggle" do
    test "starts in direct mode showing the direct form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#connect-form")
      refute has_element?(view, "#ssh-connect-form")
    end

    test "switching to SSH mode shows the SSH form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#mode-toggle", %{"mode" => "ssh"}) |> render_change()

      assert has_element?(view, "#ssh-connect-form")
      refute has_element?(view, "#connect-form")
    end

    test "switching back to direct mode restores the direct form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#mode-toggle", %{"mode" => "ssh"}) |> render_change()
      view |> form("#mode-toggle", %{"mode" => "direct"}) |> render_change()

      assert has_element?(view, "#connect-form")
      refute has_element?(view, "#ssh-connect-form")
    end

    test "mode toggle is present on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#mode-toggle")
      assert has_element?(view, "#mode-direct")
      assert has_element?(view, "#mode-ssh")
    end
  end

  describe "SSH form structure" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> form("#mode-toggle", %{"mode" => "ssh"}) |> render_change()
      %{view: view}
    end

    test "shows all required SSH form fields", %{view: view} do
      assert has_element?(view, "#ssh-connect-form")
      assert has_element?(view, "#ssh-connect-btn")
    end

    test "shows Agent auth as default selected", %{view: view} do
      assert has_element?(view, "#ssh-auth-agent[checked]")
      refute has_element?(view, "#ssh-auth-password[checked]")
    end

    test "password field is hidden by default", %{view: view} do
      refute has_element?(view, ~s|[for="ssh_password"]|)
    end

    test "switching to password auth reveals the password field", %{view: view} do
      view
      |> form("#ssh-connect-form", %{"ssh" => %{"auth_method" => "password"}})
      |> render_change()

      assert has_element?(view, "#ssh_password")
    end

    test "switching back to agent hides the password field", %{view: view} do
      view
      |> form("#ssh-connect-form", %{"ssh" => %{"auth_method" => "password"}})
      |> render_change()

      assert has_element?(view, "#ssh_password")

      view
      |> form("#ssh-connect-form", %{"ssh" => %{"auth_method" => "agent"}})
      |> render_change()

      refute has_element?(view, "#ssh_password")
    end
  end

  describe "SSH form validation" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> form("#mode-toggle", %{"mode" => "ssh"}) |> render_change()
      %{view: view}
    end

    test "shows errors on submit with empty form", %{view: view} do
      view
      |> form("#ssh-connect-form", %{"ssh" => %{}})
      |> render_submit()

      assert has_element?(view, "#ssh_ssh_user")
      assert has_element?(view, "#ssh_ssh_host")
    end

    test "shows node_name format error on submit", %{view: view} do
      view
      |> form("#ssh-connect-form", %{
        "ssh" => %{
          "ssh_user" => "alice",
          "ssh_host" => "bastion.example.com",
          "node_name" => "noatsign",
          "cookie" => "secret"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "name@host"
    end

    test "requires password field when password auth is selected", %{view: view} do
      view
      |> form("#ssh-connect-form", %{
        "ssh" => %{
          "ssh_user" => "alice",
          "ssh_host" => "bastion.example.com",
          "node_name" => "myapp@10.0.0.5",
          "cookie" => "secret",
          "auth_method" => "password"
        }
      })
      |> render_submit()

      assert has_element?(view, "#ssh_password")
      html = render(view)
      assert html =~ "can&#39;t be blank"
    end
  end

  describe "connected state in SSH mode" do
    test "disables the SSH form when a node is connected mid-session", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> form("#mode-toggle", %{"mode" => "ssh"}) |> render_change()

      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      Phoenix.PubSub.broadcast(
        Voyager.PubSub,
        NodeSession.topic(),
        {:node_connected, :demo@localhost}
      )

      _ = render(view)

      assert has_element?(view, "#ssh-connect-form.pointer-events-none")
      assert has_element?(view, "#ssh-connect-btn[disabled]")
    end

    test "disables mode toggle when connected at mount", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#mode-ssh[disabled]")
      assert has_element?(view, "#mode-direct[disabled]")
    end

    test "disables the direct form when connected at mount", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#connect-form.pointer-events-none")
      assert has_element?(view, "#connect-btn[disabled]")
    end
  end
end
