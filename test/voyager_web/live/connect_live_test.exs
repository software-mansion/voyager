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
    test "navigates to the settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#open-settings")

      {:ok, settings_view, _html} =
        view |> element("#open-settings") |> render_click() |> follow_redirect(conn)

      assert has_element?(settings_view, "#distribution-settings-form")
    end
  end
end
