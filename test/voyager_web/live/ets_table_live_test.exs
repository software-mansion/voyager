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

    assert has_element?(view, "#ets-lookup-record-0")
    refute has_element?(view, "#ets-lookup-error")
  end

  test "a row keyed by an intact tuple can be looked up", %{conn: conn} do
    name = named_table(:set)
    :ets.insert(name, {{:user, [1 | 2]}, 1})

    view = fetch_records(conn, name)

    refute has_element?(view, "#ets-records-0-lookup[aria-disabled]")

    view |> element("#ets-records-0-lookup") |> render_click()
    render_async(view, 2_000)

    assert has_element?(view, "#ets-lookup-record-0")
    refute has_element?(view, "#ets-lookup-empty")
  end

  test "a row whose struct key was cut by the budget cannot be looked up", %{conn: conn} do
    name = named_table(:set)

    :ets.insert(
      name,
      {%Version{major: 1, minor: 0, patch: 0, pre: [:binary.copy("P", 5_000)]}, 1}
    )

    view = fetch_records(conn, name)

    assert has_element?(view, "#ets-records-0-lookup[aria-disabled='true']")
    refute has_element?(view, "#ets-records-0-lookup[phx-click]")
    assert has_element?(view, "#ets-records-0-truncated")
  end

  test "a row whose key was cut by the budget cannot be looked up", %{conn: conn} do
    name = named_table(:set)
    :ets.insert(name, {{:user, :binary.copy("k", 5_000)}, 1})

    view = fetch_records(conn, name)

    assert has_element?(view, "#ets-records-0-lookup[aria-disabled='true']")
    refute has_element?(view, "#ets-records-0-lookup[disabled]")
    refute has_element?(view, "#ets-records-0-lookup[phx-click]")

    assert has_element?(
             view,
             "#ets-records-0-lookup-tip[data-tooltip-target='#ets-records-0-lookup-tip-tip']"
           )

    assert has_element?(view, "#ets-records-0-truncated")
  end

  for keypos <- [2, 6] do
    test "the key at keypos #{keypos} is bold in the row preview", %{conn: conn} do
      keypos = unquote(keypos)
      record = Tuple.insert_at({:a, :b, :c, :d, :e, :f}, keypos - 1, :the_key)
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set, keypos: keypos])
      :ets.insert(name, record)

      view = fetch_records(conn, name)

      assert has_element?(view, "#ets-records-0-toggle", inspect(record))
      assert has_element?(view, "#ets-records-0-key.font-bold.text-primary")
      assert text(view, "#ets-records-0-key") == ":the_key"
    end
  end

  test "a collection key keeps the inspect limit it has inside the record", %{conn: conn} do
    record = {:a, :b, :c, Enum.to_list(1..30), :d}
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set, keypos: 4])
    :ets.insert(name, record)

    view = fetch_records(conn, name)

    row = inspect(record, limit: 20, printable_limit: 128, width: :infinity)
    assert has_element?(view, "#ets-records-0-toggle", row)
    assert text(view, "#ets-records-0-key") == "[#{Enum.join(1..16, ", ")}, ...]"
  end

  for type <- [:bag, :duplicate_bag] do
    test "a #{type} key pages its records in the sidebar", %{conn: conn} do
      name = named_table(unquote(type))
      :ets.insert(name, for(i <- 1..15, do: {:k, record_value(unquote(type), i)}))

      view = open_lookup(conn, name)

      assert lookup_record_count(view) == 10
      assert lookup_page_label(view) == "1 / 2"
      refute has_element?(view, "#ets-lookup-pager-prev:not([disabled])")

      view |> element("#ets-lookup-pager-next") |> render_click()
      render_async(view, 2_000)

      assert lookup_record_count(view) == 5
      assert lookup_page_label(view) == "2 / 2"
      assert has_element?(view, "#ets-lookup-pager-next[disabled]")

      view |> element("#ets-lookup-pager-prev") |> render_click()
      render_async(view, 2_000)

      assert lookup_record_count(view) == 10
    end
  end

  test "a new lookup page size restarts the key from its first page", %{conn: conn} do
    name = named_table(:bag)
    :ets.insert(name, for(i <- 1..15, do: {:k, i}))

    view = open_lookup(conn, name)
    view |> element("#ets-lookup-pager-next") |> render_click()
    render_async(view, 2_000)

    view
    |> element("#ets-lookup-pager-page-size-form")
    |> render_change(%{"page_size" => "5"})

    render_async(view, 2_000)

    assert lookup_record_count(view) == 5
    assert has_element?(view, "#ets-lookup-pager-prev[disabled]")
  end

  test "a bag key too large to copy shows the error in the sidebar", %{conn: conn} do
    name = named_table(:duplicate_bag)
    :ets.insert(name, for(i <- 1..200_000, do: {:k, i}))

    view = open_lookup(conn, name)

    assert has_element?(view, "#ets-lookup-error")
    refute has_element?(view, "#ets-lookup-record-0")
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

  defp text(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp open_lookup(conn, name) do
    view = fetch_records(conn, name)

    view |> element("#ets-records-0-lookup") |> render_click()
    render_async(view, 2_000)

    assert has_element?(view, "#ets-lookup-sidebar")
    view
  end

  defp lookup_page_label(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ets-lookup-pager .font-mono.pointer-events-none")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp lookup_record_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ets-lookup-records > [id^=ets-lookup-record-]")
    |> Enum.count()
  end

  defp record_value(:bag, i), do: i
  defp record_value(:duplicate_bag, _i), do: 1
end
