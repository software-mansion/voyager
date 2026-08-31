defmodule VoyagerWeb.ProcessDetailsLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes

  @node_name "demo@localhost"

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  defp path(pid_string), do: "/node/#{@node_name}/processes/#{pid_string}"

  test "renders the selected pid", %{conn: conn} do
    {:ok, view, _html} = live(conn, path("<0.123.0>"))

    assert has_element?(view, "h1", "<0.123.0>")
  end

  test "offers a link back to the process list", %{conn: conn} do
    {:ok, view, _html} = live(conn, path("<0.123.0>"))

    href = "/node/#{URI.encode_www_form(@node_name)}/processes"

    assert has_element?(view, ~s|#back-to-processes[href="#{href}"]|)
  end

  test "renders the placeholder rather than process details", %{conn: conn} do
    {:ok, view, _html} = live(conn, path("<0.123.0>"))

    html = render(view)

    assert html =~ "Coming soon"
    # The real page is VOY-25; nothing should be fetched or rendered here yet.
    refute html =~ "Memory and Garbage Collection"
  end

  test "does not call the remote node", %{conn: conn} do
    # No Mox expectations are set, so any :erpc call would fail the test.
    {:ok, view, _html} = live(conn, path("<0.123.0>"))

    assert has_element?(view, "#back-to-processes")
  end
end
