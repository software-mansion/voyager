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

      assert render(view) =~ "Select one or more applications to inspect"
    end

    test "shows available applications as checkboxes", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      assert has_element?(view, "input[type='checkbox'][value='voyager_fixture']")
    end

    test "redirects to / for unknown node", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/node/totally_unknown_node_xyz_123/supervision-tree")
    end
  end

  describe "app selection and tree fetch" do
    test "first fetch pushes a full payload and attaches the hook element", %{
      conn: conn,
      peer: peer
    } do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      await_fetch!(view)

      assert_push_event(view, "tree-data", %{kind: "full"} = payload)
      assert payload.status in [:ok, :partial]
      assert is_map(payload.nodes)
      assert map_size(payload.nodes) > 0

      assert Map.has_key?(payload.nodes, "app:voyager_fixture")

      assert has_element?(view, "#supervision-tree-body[phx-hook='SupervisionTree']")
    end

    test "refresh without scope change pushes a delta payload", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      await_fetch!(view)
      assert_push_event(view, "tree-data", %{kind: "full"})

      view
      |> element("#supervision-tree-refresh")
      |> render_click()

      await_fetch!(view)

      assert_push_event(view, "tree-data", %{kind: "delta"} = payload)
      assert payload.status in [:ok, :partial]
      assert Map.has_key?(payload, :added)
      assert Map.has_key?(payload, :removed)
      assert Map.has_key?(payload, :updated)
    end

    test "selecting no apps keeps status idle", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

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
    test "changing depth resets the tree and the next push is full", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      await_fetch!(view)
      assert_push_event(view, "tree-data", %{kind: "full"})

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "4"})
      |> render_change()

      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      assert assigns.depth == 4
      assert is_nil(assigns.last_tree_flat)

      await_fetch!(view)
      assert_push_event(view, "tree-data", %{kind: "full"})
    end
  end

  describe "toggle expand" do
    test "toggle-expand event adds pid to expanded_pids", %{
      conn: conn,
      peer: peer
    } do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      await_fetch!(view)
      assert_push_event(view, "tree-data", %{kind: "full", nodes: nodes})

      # Find any real-pid key (e.g. "<0.123.0>") in the payload.
      pid_key =
        nodes
        |> Map.keys()
        |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, "<")))

      assert pid_key, "expected at least one real-pid key in payload"

      render_hook(view, "toggle-expand", %{"pid" => pid_key})

      pid = pid_key |> String.to_charlist() |> :erlang.list_to_pid()

      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      assert MapSet.member?(assigns.expanded_pids, pid)
    end
  end

  describe "refresh-now event" do
    test "refresh-now button triggers a fetch when apps are selected", %{conn: conn, peer: peer} do
      {:ok, view, _html} = live(conn, "/node/#{peer.node}/supervision-tree")

      view
      |> form("#supervision-tree-controls", %{"apps" => ["voyager_fixture"], "depth" => "2"})
      |> render_change()

      await_fetch!(view)

      view
      |> element("#supervision-tree-refresh")
      |> render_click()

      %{socket: %{assigns: after_refresh}} = :sys.get_state(view.pid)
      assert not is_nil(after_refresh.in_flight) or after_refresh.status == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp await_fetch!(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

    if in_flight = assigns.in_flight do
      task_pid = in_flight.task.pid
      ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 3_000
      _ = :sys.get_state(view.pid)
    end

    :ok
  end
end
