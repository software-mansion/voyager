defmodule VoyagerWeb.ConnectLiveTest do
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

  describe "distribution settings modal" do
    test "opens and closes from the connect page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#distribution-settings-modal")

      view |> element("#open-distribution-settings") |> render_click()
      assert has_element?(view, "#distribution-settings-modal")
      assert has_element?(view, "#distribution-settings-form")

      view |> element("#close-distribution-settings") |> render_click()
      refute has_element?(view, "#distribution-settings-modal")
    end

    test "saves the distribution suffix setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#open-distribution-settings") |> render_click()

      view
      |> form("#distribution-settings-form", %{
        "distribution_settings" => %{"distribution_suffix" => "_test"}
      })
      |> render_submit()

      assert Settings.get(:distribution_suffix, "") == "_test"
      refute has_element?(view, "#distribution-settings-modal")
      assert render(view) =~ "Distribution suffix saved"
    end

    test "disables the form while a node is connected", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#open-distribution-settings") |> render_click()

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
  end
end
