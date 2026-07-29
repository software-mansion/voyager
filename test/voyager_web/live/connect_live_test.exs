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
    end)

    :ok
  end

  describe "settings link" do
    test "links to the settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#open-settings[href="/settings?return_to=%2F"]|)
    end
  end

  describe "onboarding popup" do
    test "shows on first launch and dismissing it persists acceptance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#onboarding-modal")
      refute Settings.get(:terms_accepted, false)

      view |> element("#onboarding-continue") |> render_click()

      refute has_element?(view, "#onboarding-modal")
      assert Settings.get(:terms_accepted, false)
    end

    test "does not show once terms have been accepted", %{conn: conn} do
      Settings.put(:terms_accepted, true)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#onboarding-modal")
    end
  end
end
