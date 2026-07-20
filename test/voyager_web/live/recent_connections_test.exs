defmodule VoyagerWeb.ConnectLive.RecentConnectionsTest do
  @moduledoc """
  Exercises the shared `RecentConnections` hook through the direct-connect panel:
  streaming the favourites/recent split and the pin/unpin/delete lifecycle.
  """
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Fakes
  alias Voyager.NodeSession

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)

    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)

    :ok
  end

  defp insert_connection(node_name, opts \\ []) do
    {:ok, conn} = ConnectionActions.upsert_connected(node_name, cookie: "secret")

    if Keyword.get(opts, :pinned, false) do
      {:ok, pinned} = ConnectionActions.pin(conn.id)
      pinned
    else
      conn
    end
  end

  describe "favourites and recent lists" do
    test "streams pinned rows under favourites and unpinned rows under recent", %{conn: conn} do
      recent = insert_connection("recent@127.0.0.1")
      pinned = insert_connection("pinned@127.0.0.1", pinned: true)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#pinned-connections #pinned_connections-#{pinned.id}")
      assert has_element?(view, "#recent-connections #recent_connections-#{recent.id}")
    end

    test "shows neither section when there are no saved connections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#pinned-connections")
      refute has_element?(view, "#recent-connections")
    end
  end

  describe "pin/unpin/delete via the shared hook" do
    test "pinning a recent connection moves it into favourites", %{conn: conn} do
      recent = insert_connection("movable@127.0.0.1")

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#pinned-connections")
      assert has_element?(view, "#recent_connections-#{recent.id}")

      view
      |> element(~s|#recent_connections-#{recent.id} button[phx-click="pin"]|)
      |> render_click()

      assert has_element?(view, "#pinned_connections-#{recent.id}")
      refute has_element?(view, "#recent-connections")
    end

    test "unpinning a favourite moves it back to recent", %{conn: conn} do
      pinned = insert_connection("fav@127.0.0.1", pinned: true)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#pinned_connections-#{pinned.id}")

      view
      |> element(~s|#pinned_connections-#{pinned.id} button[phx-click="unpin"]|)
      |> render_click()

      assert has_element?(view, "#recent_connections-#{pinned.id}")
      refute has_element?(view, "#pinned-connections")
    end

    test "deleting a connection removes its row", %{conn: conn} do
      recent = insert_connection("gone@127.0.0.1")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#recent_connections-#{recent.id}")

      view
      |> element(~s|#recent_connections-#{recent.id} button[phx-click="delete_connection"]|)
      |> render_click()

      refute has_element?(view, "#recent_connections-#{recent.id}")
      refute has_element?(view, "#recent-connections")
    end
  end
end
