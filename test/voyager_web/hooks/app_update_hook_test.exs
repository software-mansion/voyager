defmodule VoyagerWeb.Hooks.AppUpdateHookTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Services.AppUpdater

  setup do
    on_exit(fn -> :sys.replace_state(AppUpdater, fn _ -> nil end) end)
  end

  test "hides the update button when there is no update", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#install-app-update")
  end

  test "shows the announced update and marks it as installing on click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    announce("available:9.9.9")

    assert has_element?(view, "#install-app-update", "Update to v9.9.9")

    view |> element("#install-app-update") |> render_click()

    assert has_element?(view, "#install-app-update[disabled]", "Updating")
    assert %{status: :installing} = AppUpdater.current()
  end

  test "offers a retry after a failed install", %{conn: conn} do
    announce("available:9.9.9")
    :ok = AppUpdater.install()
    announce("failed")

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#install-app-update:not([disabled])", "Retry update")
  end

  test "rejects install when there is no update" do
    assert {:error, :no_update} = AppUpdater.install()
  end

  defp announce(message) do
    send(AppUpdater, message)
    _ = :sys.get_state(AppUpdater)
  end
end
