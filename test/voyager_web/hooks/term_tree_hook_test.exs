defmodule VoyagerWeb.Hooks.TermTreeHookTest do
  use VoyagerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.TermTreeTestLive

  defp mount_inspector(conn, terms) do
    {:ok, view, _html} = live_isolated(conn, TermTreeTestLive)

    for {id, term} <- terms, do: send(view.pid, {:put_term, id, term})

    render(view)

    view
  end

  describe "put_term/3" do
    test "seeds the state the inspector renders with", %{conn: conn} do
      view = mount_inspector(conn, [{"term", [1, [2, 3]]}])

      assert has_element?(view, "li#term-1-0")
    end

    test "drops what the previous term had expanded", %{conn: conn} do
      view = mount_inspector(conn, [{"term", %{a: %{b: 1}}}])

      view |> element("#term-0-toggle") |> render_click()
      assert has_element?(view, "li#term-0-0")

      send(view.pid, {:put_term, "term", %{a: %{b: 1}}})
      render(view)

      refute has_element?(view, "li#term-0-0")
    end
  end

  describe "term-toggle" do
    test "opens a closed branch", %{conn: conn} do
      view = mount_inspector(conn, [{"term", %{a: %{b: 1}}}])

      refute has_element?(view, "li#term-0-0")

      view |> element("#term-0-toggle") |> render_click()

      assert has_element?(view, "li#term-0-0")
    end

    test "closes an open branch", %{conn: conn} do
      view = mount_inspector(conn, [{"term", %{a: 1}}])

      assert has_element?(view, "li#term-0")

      view |> element("#term-root-toggle") |> render_click()

      refute has_element?(view, "li#term-0")
    end

    test "ignores an inspector it holds no state for", %{conn: conn} do
      view = mount_inspector(conn, [{"term", %{a: 1}}])

      render_click(view, "term-toggle", %{"id" => "missing", "path" => "0"})

      assert has_element?(view, "li#term-0")
    end

    test "ignores a path that is not a path", %{conn: conn} do
      view = mount_inspector(conn, [{"term", %{a: %{b: 1}}}])

      render_click(view, "term-toggle", %{"id" => "term", "path" => "not-a-path"})

      assert has_element?(view, "li#term-0")
      refute has_element?(view, "li#term-0-0")
    end
  end

  describe "term-window" do
    test "pages in the next window of children", %{conn: conn} do
      view = mount_inspector(conn, [{"term", Enum.to_list(1..60)}])

      assert has_element?(view, "#term-root-more", "+10 more")
      refute has_element?(view, "li#term-59")

      view |> element("#term-root-more") |> render_click()

      assert has_element?(view, "li#term-59")
      refute has_element?(view, "#term-root-more")
    end

    test "ignores an unknown inspector", %{conn: conn} do
      view = mount_inspector(conn, [{"term", Enum.to_list(1..60)}])

      render_click(view, "term-window", %{"id" => "missing", "path" => ""})

      assert has_element?(view, "#term-root-more", "+10 more")
    end
  end

  describe "several inspectors on one page" do
    test "each keeps its own expansion state", %{conn: conn} do
      view = mount_inspector(conn, [{"left", %{a: %{b: 1}}}, {"right", %{a: %{b: 1}}}])

      view |> element("#left-0-toggle") |> render_click()

      assert has_element?(view, "li#left-0-0")
      refute has_element?(view, "li#right-0-0")
    end
  end

  test "events the hook does not own reach the LiveView", %{conn: conn} do
    view = mount_inspector(conn, [{"term", %{a: 1}}])

    assert view |> element("#ping") |> render_click() =~ "pings: 1"
  end
end
