defmodule VoyagerWeb.SupervisionTreeLiveTest do
  # async: false because some tests mutate the global `:mock_remote_error`
  # application env and the async fetch runs under the shared TaskSupervisor.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @path "/node/demo@localhost/supervision-tree"

  setup do
    # Inject an active session so the NodeSessionHook on_mount lets us through.
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  describe "mount with a connected node" do
    test "renders the node name header", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "h1", @node_name)
    end

    test "starts idle, waiting for the first fetch", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#supervision-tree-controls")
      assert render(view) =~ "waiting for first fetch"
      assert render(view) =~ "idle"
    end

    test "lists the available applications as checkboxes", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s|input[name="tree_controls[apps][]"][value="demo_app"]|)
      assert has_element?(view, ~s|input[name="tree_controls[apps][]"][value="another_app"]|)
    end

    test "shows the empty state when no applications are selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render(view) =~ "No applications selected"
      refute has_element?(view, "#supervision-tree-body")
    end

    test "does not render an error alert", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#supervision-tree-errors")
    end
  end

  describe "selecting applications" do
    test "marks the chosen application as checked", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#supervision-tree-controls", %{"tree_controls" => %{"apps" => ["demo_app"]}})
      |> render_change()

      assert has_element?(
               view,
               ~s|input[name="tree_controls[apps][]"][value="demo_app"][checked]|
             )
    end

    test "kicks off a fetch and renders the graph body", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("#supervision-tree-controls", %{"tree_controls" => %{"apps" => ["demo_app"]}})
        |> render_change()

      # The fetch starts immediately, so the status flips to loading and the
      # graph container replaces the empty state. Asserting on the loading
      # state keeps this deterministic regardless of when the async task lands.
      assert html =~ "loading"
      assert has_element?(view, "#supervision-tree-body")
      refute render(view) =~ "No applications selected"
    end
  end

  describe "depth control" do
    test "shows a validation error when depth is below the minimum", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("#supervision-tree-controls", %{"tree_controls" => %{"depth" => "1"}})
        |> render_change()

      assert html =~ "min 2"
    end

    test "accepts a valid depth without a validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("#supervision-tree-controls", %{"tree_controls" => %{"depth" => "4"}})
        |> render_change()

      refute html =~ "min 2"
    end
  end

  describe "controls" do
    test "collapses and expands the applications section", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      app_checkbox = ~s|input[name="tree_controls[apps][]"][value="demo_app"]|
      assert has_element?(view, app_checkbox)

      # Collapsing hides the application checkboxes (the collapsible only
      # renders its inner content while open).
      view |> element(~s|button[phx-click="toggle-apps-open"]|) |> render_click()
      refute has_element?(view, app_checkbox)

      # Expanding again brings them back.
      view |> element(~s|button[phx-click="toggle-apps-open"]|) |> render_click()
      assert has_element?(view, app_checkbox)
    end

    test "refresh-now with no applications selected stays idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> element("#supervision-tree-refresh") |> render_click()

      assert render(view) =~ "idle"
      refute has_element?(view, "#supervision-tree-body")
    end
  end

  describe "graph interaction events" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#supervision-tree-controls", %{"tree_controls" => %{"apps" => ["demo_app"]}})
      |> render_change()

      %{view: view}
    end

    test "selecting a node before any data has loaded is a no-op", %{view: view} do
      render_hook(view, "select-node", %{"key" => "missing"})

      assert Process.alive?(view.pid)
    end
  end

  describe "mount when the application list cannot be fetched" do
    setup do
      Application.put_env(:voyager, :mock_remote_error, :noconnection)
      on_exit(fn -> Application.delete_env(:voyager, :mock_remote_error) end)
      :ok
    end

    test "renders an error alert and the error status", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#supervision-tree-errors")
      assert render(view) =~ "error"
      refute has_element?(view, "#supervision-tree-body")
    end
  end

  describe "mount without a matching session" do
    test "redirects to the connect page", %{conn: conn} do
      Fakes.put_session(nil)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, @path)
    end
  end
end
