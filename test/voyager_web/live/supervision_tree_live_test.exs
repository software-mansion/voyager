defmodule VoyagerWeb.SupervisionTreeLiveTest do
  # async: false because we use Mox global mode (the supervision-tree walk runs
  # in tasks under the shared TaskSupervisor, so erpc expectations must be
  # reachable from any process).
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @path "/node/demo@localhost/supervision-tree"

  # The OTP applications the mocked node reports running. The LiveView maps
  # these to `{app, version}` and renders a checkbox per app.
  @apps [
    {:demo_app, ~c"Demo app", ~c"1.0.0"},
    {:another_app, ~c"Another app", ~c"2.0.0"}
  ]

  setup :set_mox_global

  setup do
    # Inject an active session so the NodeSessionHook on_mount lets us through.
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    stub_supervision_erpc()
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

  describe "clearing all applications" do
    test "unchecks every selected application", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#supervision-tree-controls", %{
        "tree_controls" => %{"apps" => ["demo_app", "another_app"]}
      })
      |> render_change()

      assert has_element?(
               view,
               ~s|input[name="tree_controls[apps][]"][value="demo_app"][checked]|
             )

      view |> element("#supervision-tree-clear-apps") |> render_click()

      refute has_element?(
               view,
               ~s|input[name="tree_controls[apps][]"][value="demo_app"][checked]|
             )

      refute has_element?(
               view,
               ~s|input[name="tree_controls[apps][]"][value="another_app"][checked]|
             )
    end

    test "returns to the empty state and tears down the graph body", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#supervision-tree-controls", %{"tree_controls" => %{"apps" => ["demo_app"]}})
      |> render_change()

      assert has_element?(view, "#supervision-tree-body")

      view |> element("#supervision-tree-clear-apps") |> render_click()

      assert render(view) =~ "No applications selected"
      refute has_element?(view, "#supervision-tree-body")
    end

    test "is unavailable when no applications are selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render(view) =~ "No applications selected"
      refute has_element?(view, "#supervision-tree-clear-apps")
      refute has_element?(view, "#supervision-tree-body")
    end
  end

  describe "depth control" do
    test "shows a validation error when depth is below the minimum and removes the error when depth is changed to valid",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> form("#supervision-tree-controls", %{"tree_controls" => %{"depth" => "1"}})
        |> render_change()

      assert html =~ "min 2"

      html =
        view
        |> form("#supervision-tree-controls", %{"tree_controls" => %{"depth" => "3"}})
        |> render_change()

      refute html =~ "min 2"
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

      # The collapsible toggle carries the `aria-expanded` attribute only while
      # open (HEEx drops a `false` boolean attribute entirely).
      assert has_element?(view, "#apps[aria-expanded]")

      view |> element("#apps") |> render_click()
      refute has_element?(view, "#apps[aria-expanded]")

      view |> element("#apps") |> render_click()
      assert has_element?(view, "#apps[aria-expanded]")
    end

    test "refresh_now with no applications selected stays idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> element("#refresh-interval-refresh-now-button") |> render_click()

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
      # Simulate an unreachable node: every erpc call raises a noconnection
      # error, which `Remote` translates into `{:error, :noconnection}`.
      stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      :ok
    end

    test "renders an error alert and the error status", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#supervision-tree-errors")
      assert render(view) =~ "error"
      refute has_element?(view, "#supervision-tree-body")
    end

    test "dismissing the errors removes the error alert", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#supervision-tree-errors")

      view
      |> element(~s|#supervision-tree-errors button[aria-label="Dismiss errors"]|)
      |> render_click()

      refute has_element?(view, "#supervision-tree-errors")
    end
  end

  describe "mount without a matching session" do
    test "redirects to the connect page", %{conn: conn} do
      Fakes.put_session(nil)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, @path)
    end
  end

  # Stubs `Voyager.Erpc` so the supervision-tree backend (Remote + Walker) sees
  # a small, reachable node: two running applications, each with a root
  # supervisor that has no children. None of the tests assert on tree contents,
  # so the shape is intentionally minimal — the point is that the fetch resolves
  # cleanly (status :ok, no errors) instead of crashing on an unstubbed call.
  defp stub_supervision_erpc do
    stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
      supervision_reply(mod, fun, args)
    end)
  end

  defp supervision_reply(:application, :which_applications, []), do: @apps

  defp supervision_reply(:lists, :map, [fun, list]) do
    case mfa(fun) do
      {:application_controller, :get_master, 1} ->
        Enum.map(list, fn _app -> self() end)

      {:application_master, :get_child, 1} ->
        Enum.map(list, fn _master -> {self(), :fake_app} end)

      {:supervisor, :which_children, 1} ->
        Enum.map(list, fn _sup -> [] end)

      {:supervisor, :count_children, 1} ->
        Enum.map(list, fn _sup -> [specs: 0, active: 0, supervisors: 0, workers: 0] end)
    end
  end

  defp supervision_reply(:lists, :zipwith, [_fun, pids, _keys]) do
    Enum.map(pids, fn _pid -> :undefined end)
  end

  defp mfa(fun) do
    info = :erlang.fun_info(fun)
    {info[:module], info[:name], info[:arity]}
  end
end
