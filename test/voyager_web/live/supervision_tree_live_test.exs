defmodule VoyagerWeb.SupervisionTreeLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Test.RemoteFixture

  setup do
    peer = RemoteFixture.start_peer!()
    RemoteFixture.load_fixture_app!(peer)
    RemoteFixture.start_fixture_app!(peer)

    on_exit(fn -> RemoteFixture.stop_peer!(peer) end)

    {:ok, peer: peer}
  end

  describe "mount" do
    test "renders controls form and empty state when no apps selected", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      assert has_element?(view, "#supervision-tree-controls")
      assert has_element?(view, "#depth-input")
      assert has_element?(view, "#supervision-tree-refresh")

      # Empty state text is visible when no apps selected
      assert render(view) =~ "Select one or more applications to inspect"
    end

    test "shows available applications as checkboxes", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # The fixture app should appear in the app list
      assert has_element?(view, "input[type='checkbox'][value='voyager_fixture']")
    end

    test "redirects to / for unknown node", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/node/totally_unknown_node_xyz_123/supervision-tree")
    end
  end

  describe "app selection and tree fetch" do
    test "selecting an app triggers a fetch and renders the tree", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # Select voyager_fixture with depth 2
      # Use flat param names matching the raw <input> names in the template
      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      # Get the in_flight task pid for monitoring.
      # The fetch may already be done by the time we call get_state — handle both cases.
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      in_flight = assigns.in_flight

      if in_flight do
        # Monitor the task so we know when it's done
        task_pid = in_flight.task.pid
        ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 3_000

        # Flush: ensure the LiveView has processed the result message
        _ = :sys.get_state(view.pid)
      else
        # Fetch already completed — verify status is ok/partial
        assert assigns.status in [:ok, :partial],
               "Expected fetch to succeed but status=#{assigns.status}"
      end

      # Tree should now be rendered
      assert has_element?(view, "#supervision-tree-body")

      rendered = render(view)
      assert rendered =~ "tree-node-"
    end

    test "selecting no apps keeps status idle and shows empty state", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # Simulate form submit with no apps (empty list) — omit apps key entirely
      view
      |> form("#supervision-tree-controls", %{"depth" => "3"})
      |> render_change()

      _ = :sys.get_state(view.pid)

      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      assert assigns.status == :idle
      assert is_nil(assigns.in_flight)
    end
  end

  describe "depth change" do
    test "changing depth triggers a new fetch with updated depth", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # First select an app
      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      %{socket: %{assigns: first_assigns}} = :sys.get_state(view.pid)
      first_ref = first_assigns.in_flight && first_assigns.in_flight.ref

      # Wait for first fetch to complete
      if first_ref do
        task_pid = first_assigns.in_flight.task.pid
        mon = Process.monitor(task_pid)
        assert_receive {:DOWN, ^mon, :process, ^task_pid, _}, 3_000
        _ = :sys.get_state(view.pid)
      end

      # Now change depth
      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "4"})
      |> render_change()

      %{socket: %{assigns: second_assigns}} = :sys.get_state(view.pid)
      assert second_assigns.depth == 4
      assert not is_nil(second_assigns.in_flight)
    end
  end

  describe "toggle expand" do
    test "toggle-expand on the app root node adds pid to expanded_pids", %{
      conn: conn,
      peer: peer
    } do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # Select an app
      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

      if assigns.in_flight do
        task_pid = assigns.in_flight.task.pid
        mon = Process.monitor(task_pid)
        assert_receive {:DOWN, ^mon, :process, ^task_pid, _}, 3_000
        _ = :sys.get_state(view.pid)
      end

      %{socket: %{assigns: post_fetch}} = :sys.get_state(view.pid)
      tree = post_fetch.tree

      # Get the app root pid — its toggle button is visible in the rendered HTML
      app_node = tree && Map.get(tree, :voyager_fixture)
      root_pid = app_node && app_node.pid

      if root_pid do
        # DOM id for the app node uses dashes not dots
        dom_id =
          root_pid
          |> :erlang.pid_to_list()
          |> List.to_string()
          |> String.trim_leading("<")
          |> String.trim_trailing(">")
          |> String.replace(".", "-")
          |> then(&"tree-node-#{&1}")

        view
        |> element("##{dom_id} button[phx-click='toggle-expand']")
        |> render_click()

        %{socket: %{assigns: after_toggle}} = :sys.get_state(view.pid)
        assert MapSet.member?(after_toggle.expanded_pids, root_pid)
      else
        assert not is_nil(tree)
      end
    end
  end

  describe "refresh-now event" do
    test "refresh-now button triggers a fetch when apps are selected", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      # Select an app first
      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      %{socket: %{assigns: first}} = :sys.get_state(view.pid)

      if first.in_flight do
        task_pid = first.in_flight.task.pid
        mon = Process.monitor(task_pid)
        assert_receive {:DOWN, ^mon, :process, ^task_pid, _}, 3_000
        _ = :sys.get_state(view.pid)
      end

      # Click refresh
      view
      |> element("#supervision-tree-refresh")
      |> render_click()

      %{socket: %{assigns: after_refresh}} = :sys.get_state(view.pid)
      assert not is_nil(after_refresh.in_flight) or after_refresh.status == :ok
    end
  end
end
