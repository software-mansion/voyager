defmodule VoyagerWeb.Hooks.SidebarHookTest do
  # async: false because Mox global mode: node info is fetched from a spawned task.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Voyager.Fakes, only: [stub_erpc: 1]

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @path "/node/demo@localhost"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    stub_erpc(Fakes.node_data())
    :ok
  end

  test "leaves the width to the viewport when nothing is stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#app-sidebar")
    refute has_element?(view, "#app-sidebar.mode-compact")
    refute has_element?(view, "#app-sidebar.mode-full")
  end

  test "applies the mode stored in session storage", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"session_storage" => %{"sidebar" => "compact"}})
      |> live(@path)

    assert has_element?(view, "#app-sidebar.mode-compact")
  end

  test "ignores an unknown stored mode", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"session_storage" => %{"sidebar" => "wide"}})
      |> live(@path)

    refute has_element?(view, "#app-sidebar.mode-compact")
    refute has_element?(view, "#app-sidebar.mode-full")
  end

  test "the toggle switches modes without touching the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#sidebar-compact-toggle-wide") |> render_click()
    assert has_element?(view, "#app-sidebar.mode-compact")

    view |> element("#sidebar-compact-toggle-wide") |> render_click()
    assert has_element?(view, "#app-sidebar.mode-full")

    refute_patched(view)
  end

  test "a toggle to an unknown mode falls back to the viewport default", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"session_storage" => %{"sidebar" => "compact"}})
      |> live(@path)

    render_hook(view, "toggle_sidebar", %{"mode" => "wide"})

    refute has_element?(view, "#app-sidebar.mode-compact")
    refute has_element?(view, "#app-sidebar.mode-full")
  end

  test "nav links carry no sidebar param", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"session_storage" => %{"sidebar" => "compact"}})
      |> live(@path)

    assert has_element?(view, ~s(#sidebar-nav-processes[href="/node/#{@node_name}/processes"]))
  end
end
