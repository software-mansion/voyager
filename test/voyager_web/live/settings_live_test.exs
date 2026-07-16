defmodule VoyagerWeb.SettingsLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Settings

  setup do
    previous_state = :sys.get_state(Voyager.NodeSession)
    Fakes.put_session(nil)

    on_exit(fn ->
      :sys.replace_state(Voyager.NodeSession, fn _ -> previous_state end)
      Application.delete_env(:voyager, :distribution_suffix)
    end)

    :ok
  end

  describe "layout" do
    test "renders no sidebar and a back link to the default return path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "aside")
      assert has_element?(view, ~s|a[href="/"]|)
    end

    test "back link honors the return_to param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=/node/demo@localhost")

      assert has_element?(view, ~s|a[href="/node/demo@localhost"]|)
    end

    test "ignores an unsafe return_to and falls back to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=https://evil.example")

      assert has_element?(view, ~s|a[href="/"]|)
    end

    test "ignores a protocol-relative return_to and falls back to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=//evil.example")

      assert has_element?(view, ~s|a[href="/"]|)
    end
  end

  describe "appearance" do
    test "renders theme options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s|button[data-phx-theme="light"]|)
      assert has_element?(view, ~s|button[data-phx-theme="dark"]|)
      assert has_element?(view, ~s|button[data-phx-theme="system"]|)
    end
  end

  describe "distribution settings" do
    test "saves the distribution suffix setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#distribution-settings-form", %{
        "distribution_settings" => %{"distribution_suffix" => "_test"}
      })
      |> render_submit()

      assert Settings.get(:distribution_suffix, "") == "_test"
      assert render(view) =~ "Distribution suffix saved"
    end

    test "disables the form while a node is connected", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#distribution-settings-connected")

      assert has_element?(
               view,
               ~s|#distribution_settings_distribution_suffix[disabled]|
             )

      assert has_element?(
               view,
               ~s|#distribution-settings-form button[type="submit"][disabled]|
             )
    end

    test "disables the form when locked by application config", %{conn: conn} do
      Application.put_env(:voyager, :distribution_suffix, "_locked")

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#distribution-settings-locked")

      assert has_element?(
               view,
               ~s|#distribution_settings_distribution_suffix[disabled]|
             )
    end
  end
end
