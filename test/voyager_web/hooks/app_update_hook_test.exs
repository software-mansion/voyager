defmodule VoyagerWeb.Hooks.AppUpdateHookTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Services.AppUpdater

  setup do
    previous_state = :sys.get_state(AppUpdater)
    :sys.replace_state(AppUpdater, &%{&1 | native?: true})

    on_exit(fn -> :sys.replace_state(AppUpdater, fn _ -> previous_state end) end)
  end

  test "shows no modal when there is no update", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#app-update-modal")
  end

  test "offers the announced update and marks it as installing on click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    announce("available:9.9.9")

    assert has_element?(view, "#app-update-modal", "v9.9.9")

    view |> element("#install-app-update") |> render_click()

    assert has_element?(view, "#install-app-update[disabled]", "Updating")
    assert %{status: :installing} = AppUpdater.current()
  end

  test "dismissing closes the modal and keeps the update in settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    announce("available:9.9.9")
    view |> element("#dismiss-app-update") |> render_click()

    refute has_element?(view, "#app-update-modal")

    {:ok, settings, _html} = live(conn, ~p"/settings")

    assert has_element?(settings, "#update-status", "v9.9.9 is available")

    settings |> element("#install-app-update-setting") |> render_click()

    refute has_element?(settings, "#app-update-modal")
    assert has_element?(settings, "#update-status", "Installing")
  end

  test "offers a retry after a failed install", %{conn: conn} do
    announce("available:9.9.9")
    :ok = AppUpdater.install()
    announce("failed")

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#app-update-modal", "Update failed")
    assert has_element?(view, "#install-app-update:not([disabled])", "Retry")
  end

  test "manual check reports an up to date app", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-app-update") |> render_click()

    assert has_element?(view, "#check-app-update[disabled]")
    assert has_element?(view, "#update-status", "Checking")

    announce("none")

    assert has_element?(view, "#update-status", "up to date")
    assert has_element?(view, "#check-app-update:not([disabled])")
  end

  test "manual check shows a found update in place instead of the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-app-update") |> render_click()
    announce("available:9.9.9")

    refute has_element?(view, "#app-update-modal")
    assert has_element?(view, "#install-app-update-setting", "Install v9.9.9")

    view |> element("#install-app-update-setting") |> render_click()

    refute has_element?(view, "#app-update-modal")
    assert has_element?(view, "#install-app-update-setting[disabled]")
    assert has_element?(view, "#update-status", "Installing")
  end

  test "a late startup announcement keeps a manually found update in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-app-update") |> render_click()
    announce("available:9.9.9")
    announce("available:9.9.9")

    refute has_element?(view, "#app-update-modal")
    assert has_element?(view, "#install-app-update-setting")
  end

  test "a late announcement does not interrupt an install" do
    announce("available:9.9.9")
    :ok = AppUpdater.install()
    announce("available:9.9.9")

    assert %{status: :installing} = AppUpdater.current()
  end

  test "manual check reports a failed check", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-app-update") |> render_click()
    announce("check_failed")

    assert has_element?(view, "#update-status", "Could not check")
  end

  test "a silent startup check does not change the state" do
    announce("none")

    assert AppUpdater.current() == nil
  end

  test "rejects install when there is no update" do
    assert {:error, :no_update} = AppUpdater.install()
  end

  defp announce(message) do
    send(AppUpdater, message)
    _ = :sys.get_state(AppUpdater)
  end
end
