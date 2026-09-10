defmodule VoyagerWeb.EtsTableLiveTest do
  # async: false because these tests swap the global erpc impl to the real
  # `Voyager.Erpc.Impl` and read live local ETS tables through it.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Test.EtsTable
  alias Voyager.Test.VoyagerAgentFixture

  @node_name "nonode@nohost"

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

  test "a set row can open the lookup sidebar", %{conn: conn} do
    name = named_table(:set)
    :ets.insert(name, {:k, 1})

    view = fetch_records(conn, name)

    assert has_element?(view, "#ets-records-0-lookup")

    view |> element("#ets-records-0-lookup") |> render_click()
    render_async(view, 2_000)

    assert has_element?(view, "#ets-lookup-sidebar")
  end

  test "a bag row has no lookup control and ignores open_sidebar", %{conn: conn} do
    name = named_table(:bag)
    :ets.insert(name, {:k, 1})
    :ets.insert(name, {:k, 2})

    refute_lookup_sidebar(conn, name)
  end

  test "a duplicate_bag row has no lookup control and ignores open_sidebar", %{conn: conn} do
    name = named_table(:duplicate_bag)
    :ets.insert(name, {:k, 1})
    :ets.insert(name, {:k, 1})

    refute_lookup_sidebar(conn, name)
  end

  defp named_table(type) do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, type])
    name
  end

  defp fetch_records(conn, name) do
    path = ~p"/node/#{@node_name}/ets-tables/#{inspect(name)}"
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)

    assert has_element?(view, "#ets-table-info")
    refute has_element?(view, "#ets-records-count")

    view |> element("#ets-peek-fetch") |> render_click()
    render_async(view, 2_000)

    assert has_element?(view, "#ets-records-0")
    view
  end

  defp refute_lookup_sidebar(conn, name) do
    view = fetch_records(conn, name)

    refute has_element?(view, "#ets-records-0-lookup")
    refute has_element?(view, "#ets-lookup-sidebar")

    render_click(view, "open_sidebar", %{"index" => "0"})
    render_async(view, 2_000)

    refute has_element?(view, "#ets-lookup-sidebar")
  end
end
