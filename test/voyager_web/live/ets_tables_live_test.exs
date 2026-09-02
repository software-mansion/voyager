defmodule VoyagerWeb.EtsTablesLiveTest do
  # async: false because we use Mox global mode: the remote fetch runs in an
  # async task, so erpc expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Voyager.EtsFakes
  alias Voyager.Fakes
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.EtsTablesLive
  alias VoyagerWeb.Formatters

  @node_name "demo@localhost"
  @path "/node/demo@localhost/ets-tables"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  # A small node: a public module-named table, a protected one, a bag and an
  # unnamed private table, with distinct sizes so every sort has one answer.
  defp fixtures do
    [
      EtsFakes.table(name: :ac_tab, protection: :protected, size: 12, memory: 4_096),
      EtsFakes.table(name: MyApp.Cache, type: :ordered_set, size: 900, memory: 1_048_576),
      EtsFakes.table(
        name: :secrets,
        id: make_ref(),
        named_table: false,
        protection: :private,
        size: 3,
        memory: 512
      ),
      EtsFakes.table(name: :buffer, type: :bag, size: 40, memory: 65_536)
    ]
  end

  defp by_name(tables, name), do: Enum.find(tables, &(&1.name == name))

  # Blocks the fetch until the test releases it, so the next request lands
  # mid-flight — which `render_click/1` alone cannot produce, since it waits
  # for the async to finish.
  defp stub_blocking(tables) do
    test = self()

    stub(Voyager.ErpcMock, :call, fn
      _node, :ets, :all, [], _timeout ->
        send(test, {:fetching, self()})

        receive do
          :release -> EtsFakes.ids(tables)
        end

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        EtsFakes.word_size()

      _node, :lists, :map, [_fun, ids], _timeout ->
        EtsFakes.raw_infos(tables, ids)
    end)
  end

  # The first fetch waits for the client's stored settings, so opening a page
  # includes delivering them, empty unless the test says otherwise.
  defp open(conn, tables, path \\ @path, restore \\ %{}) do
    EtsFakes.stub_list(tables)
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "restore_settings", restore)
    render_async(view)
    view
  end

  defp row(table), do: "##{EtsTablesLive.row_dom_id(table.id)}"

  # Row ids in the order the table renders them.
  defp rendered_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ets-tables-table tbody tr[id]")
    |> LazyHTML.attribute("id")
  end

  defp rows_in_order(tables, names) do
    Enum.map(names, &EtsTablesLive.row_dom_id(by_name(tables, &1).id))
  end

  # Visible text of a fragment, with the markup and the whitespace between
  # elements collapsed away.
  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp change(view, attrs) do
    view |> element("#ets-table-controls") |> render_change(%{"controls" => attrs})
  end

  defp refresh(view) do
    view |> element("#ets-tables-refresh-interval-refresh-now-button") |> render_click()
    render_async(view)
  end

  defp sort_by(view, key) do
    view |> element(~s|button[phx-value-key="#{key}"]|) |> render_click()
  end

  defp table_path(table) do
    "#{@path}?table=#{URI.encode_www_form(TableId.display(table.id))}"
  end

  # As `~p` encodes it: the node name and the table id are both path segments.
  defp details_path(table) do
    id = URI.encode(TableId.display(table.id), &URI.char_unreserved?/1)

    "/node/#{URI.encode_www_form(@node_name)}/ets-tables/#{id}"
  end

  describe "mount" do
    test "renders the node name header", %{conn: conn} do
      view = open(conn, [])

      assert has_element?(view, "h1", @node_name)
    end

    test "fetches once with the default timeout", %{conn: conn} do
      open(conn, [])

      assert_received {:fetched, 5_000}
      refute_received {:fetched, _timeout}
    end

    test "renders a row per table, largest memory first", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      assert rendered_rows(view) ==
               rows_in_order(tables, [MyApp.Cache, :buffer, :ac_tab, :secrets])
    end

    test "summarises the fetch", %{conn: conn} do
      view = open(conn, fixtures())

      summary = view |> element("#ets-tables-summary") |> render()

      assert text(summary) =~ ~r/^Fetched 4 tables in \d+ ms · 1 MB in total$/
    end

    test "shows the empty state when the node has no tables", %{conn: conn} do
      view = open(conn, [])

      assert render(view) =~ "No tables matched."
      refute has_element?(view, "#ets-tables-pager-next")
    end

    test "is an inspect page in the sidebar rather than a coming-soon one", %{conn: conn} do
      view = open(conn, [])

      nav = view |> element("#sidebar-nav-ets_tables") |> render()

      assert nav =~ "menu-active"
      refute nav =~ "Soon"
    end
  end

  describe "cells" do
    test "the name opens the table and its tooltip carries the id", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      link = view |> element(~s|#{row(cache)} td[data-column="name"] a|) |> render()

      assert link =~ "MyApp.Cache"
      assert link =~ ~s|data-phx-link="patch"|
      assert render(view) =~ ~s|id="#{EtsTablesLive.row_dom_id(cache.id)}-name-copy-text"|
    end

    test "an unnamed table shows its reference beside its name", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      secrets = by_name(tables, :secrets)

      cell = view |> element(~s|#{row(secrets)} td[data-column="name"]|) |> render()

      assert text(cell) =~ ":secrets"
      assert text(cell) =~ inspect(secrets.id)
    end

    test "a private table carries a badge", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      secrets = by_name(tables, :secrets)

      cell = view |> element("##{EtsTablesLive.row_dom_id(secrets.id)}-protection") |> render()

      assert cell =~ "badge"
      assert cell =~ "private"

      public = by_name(tables, :buffer)

      refute view |> element("##{EtsTablesLive.row_dom_id(public.id)}-protection") |> render() =~
               "badge"
    end

    test "the owner links to the process details page", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      link = view |> element(~s|#{row(cache)} td[data-column="owner"] a|) |> render()

      assert link =~ URI.encode_www_form(Formatters.format_pid(cache.owner))
    end

    test "every row links to its details page", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      assert has_element?(
               view,
               ~s|#{row(cache)} td[data-column="details"] a[href="#{details_path(cache)}"]|
             )
    end

    test "memory keeps the exact byte count reachable", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      html = render(view)

      assert html =~ ~s|id="#{EtsTablesLive.row_dom_id(cache.id)}-memory-copy-text"|
      assert html =~ "1,048,576 B"
    end
  end

  describe "sorting" do
    test "sorts locally without refetching", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      assert_received {:fetched, _timeout}

      sort_by(view, "size")

      assert rendered_rows(view) ==
               rows_in_order(tables, [MyApp.Cache, :buffer, :ac_tab, :secrets])

      refute_received {:fetched, _timeout}
    end

    test "a text column starts ascending and re-selecting it flips the order", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      sort_by(view, "name")

      assert rendered_rows(view) ==
               rows_in_order(tables, [:ac_tab, :buffer, :secrets, MyApp.Cache])

      sort_by(view, "name")

      assert rendered_rows(view) ==
               rows_in_order(tables, [MyApp.Cache, :secrets, :buffer, :ac_tab])
    end

    test "re-selecting memory flips it to smallest first", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      sort_by(view, "memory")

      assert rendered_rows(view) ==
               rows_in_order(tables, [:secrets, :ac_tab, :buffer, MyApp.Cache])

      assert view |> element(~s|th:has(button[phx-value-key="memory"])|) |> render() =~
               ~s|aria-sort="ascending"|
    end

    test "marks the default sort on the memory header", %{conn: conn} do
      view = open(conn, fixtures())

      header = view |> element(~s|th:has(button[phx-value-key="memory"])|) |> render()

      assert header =~ ~s|aria-sort="descending"|
      assert header =~ ~r/icon-move-down[^"]*text-primary/
    end

    test "sorting goes back to the first page", %{conn: conn} do
      tables = Enum.map(1..30, &EtsFakes.table(name: :"t#{&1}", memory: &1 * 8))
      view = open(conn, tables)

      view |> element("#ets-tables-pager-next") |> render_click()
      assert render(view) =~ "2 / 2"

      sort_by(view, "name")

      assert render(view) =~ "1 / 2"
    end
  end

  describe "filtering" do
    test "narrows the rows without refetching", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      assert_received {:fetched, _timeout}

      change(view, %{"search" => "CACHE"})

      assert rendered_rows(view) == rows_in_order(tables, [MyApp.Cache])
      refute_received {:fetched, _timeout}
    end

    test "matches an unnamed table by its reference", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      secrets = by_name(tables, :secrets)

      change(view, %{"search" => inspect(secrets.id)})

      assert rendered_rows(view) == [EtsTablesLive.row_dom_id(secrets.id)]
    end

    test "reports the rows shown out of those fetched", %{conn: conn} do
      view = open(conn, fixtures())

      change(view, %{"search" => "bag"})

      summary = view |> element("#ets-tables-summary") |> render()
      assert text(summary) =~ ~r/^Showing 1 of 4 tables fetched in \d+ ms · 1 MB in total$/
    end

    test "shows the empty state when nothing matches", %{conn: conn} do
      view = open(conn, fixtures())

      change(view, %{"search" => "nothing-like-this"})

      assert render(view) =~ "No tables matched."
    end

    test "survives a fetch landing while a search is set", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      change(view, %{"search" => "cache"})
      refresh(view)

      assert rendered_rows(view) == rows_in_order(tables, [MyApp.Cache])
    end
  end

  describe "pagination" do
    test "pages over the rows without refetching", %{conn: conn} do
      tables = Enum.map(1..30, &EtsFakes.table(name: :"t#{&1}", memory: (100 - &1) * 8))
      view = open(conn, tables)
      assert_received {:fetched, _timeout}

      first_page_last = by_name(tables, :t25)
      second_page_first = by_name(tables, :t26)

      assert has_element?(view, row(first_page_last))
      refute has_element?(view, row(second_page_first))

      view |> element("#ets-tables-pager-next") |> render_click()

      assert has_element?(view, row(second_page_first))
      refute has_element?(view, row(first_page_last))
      refute_received {:fetched, _timeout}
    end

    test "changing rows per page reslices", %{conn: conn} do
      tables = Enum.map(1..30, &EtsFakes.table(name: :"t#{&1}", memory: (100 - &1) * 8))
      view = open(conn, tables)

      view
      |> element("#ets-tables-pager-page-size-form")
      |> render_change(%{"page_size" => "10"})

      assert has_element?(view, row(by_name(tables, :t10)))
      refute has_element?(view, row(by_name(tables, :t11)))
      assert render(view) =~ "1 / 3"
    end

    test "editing the timeout keeps the page, a new search resets it", %{conn: conn} do
      tables = Enum.map(1..30, &EtsFakes.table(name: :"t#{&1}", memory: (100 - &1) * 8))
      view = open(conn, tables)

      view |> element("#ets-tables-pager-next") |> render_click()
      assert render(view) =~ "2 / 2"

      change(view, %{"timeout" => "10000"})
      assert render(view) =~ "2 / 2"

      change(view, %{"search" => "t"})
      assert render(view) =~ "1 / 2"
    end

    test "hides the pager when everything fits on one page", %{conn: conn} do
      view = open(conn, fixtures())

      refute has_element?(view, "#ets-tables-pager-next")
    end
  end

  describe "auto refresh" do
    test "defaults to five seconds and offers no two second option", %{conn: conn} do
      view = open(conn, [])

      select = view |> element("#ets-tables-refresh-interval") |> render()

      assert select =~ ~r/value="5000"[^>]*selected/
      refute select =~ ~s|value="2000"|
    end

    test "refetches on the tick", %{conn: conn} do
      view = open(conn, [])
      assert_received {:fetched, _timeout}

      send(view.pid, :auto_refresh)
      render_async(view)

      assert_received {:fetched, _timeout}
    end

    test "a tick landing mid-fetch waits for it instead of running concurrently", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      assert_received {:fetched, _timeout}

      stub_blocking(tables)

      view |> element("#ets-tables-refresh-interval-refresh-now-button") |> render_click()
      assert_receive {:fetching, fetch}

      # Queued, not started: the fetch under way is already paying the cost.
      send(view.pid, :auto_refresh)
      render(view)
      refute_received {:fetching, _pid}

      # The queued request replays once the running fetch lands.
      send(fetch, :release)
      render_async(view, 1_000)
      assert_receive {:fetching, replay}
      send(replay, :release)
      render_async(view, 1_000)
      refute_received {:fetching, _pid}
    end

    test "can be switched off", %{conn: conn} do
      view = open(conn, [])

      view
      |> element("#ets-tables-refresh-interval-form")
      |> render_change(%{"interval" => "off"})

      assert view |> element("#ets-tables-refresh-interval") |> render() =~
               ~r/value="off"[^>]*selected/
    end
  end

  describe "manual refresh" do
    test "refetches on demand", %{conn: conn} do
      view = open(conn, [])
      assert_received {:fetched, _timeout}

      refresh(view)

      assert_received {:fetched, _timeout}
    end

    test "a click while a fetch is in flight queues one instead of racing it", %{conn: conn} do
      view = open(conn, [])
      assert_received {:fetched, _timeout}

      stub_blocking([])

      view |> element("#ets-tables-refresh-interval-refresh-now-button") |> render_click()
      assert_receive {:fetching, fetch}

      view |> element("#ets-tables-refresh-interval-refresh-now-button") |> render_click()
      refute_received {:fetching, _pid}

      send(fetch, :release)
      render_async(view, 1_000)
      assert_receive {:fetching, replay}
      send(replay, :release)
      render_async(view, 1_000)
      refute_received {:fetching, _pid}
    end
  end

  describe "timeout control" do
    test "renders the form over the search and the timeout", %{conn: conn} do
      view = open(conn, [])

      assert has_element?(view, "#ets-table-controls")
      assert has_element?(view, "#controls_search")
      assert has_element?(view, "#controls_timeout")
    end

    test "a timeout change refetches with it after the debounce window", %{conn: conn} do
      view = open(conn, [])
      assert_received {:fetched, 5_000}

      change(view, %{"timeout" => "10000"})
      refute_received {:fetched, _timeout}

      send(view.pid, :refetch)
      render_async(view)

      assert_received {:fetched, 10_000}
    end

    test "a search change schedules no refetch", %{conn: conn} do
      view = open(conn, fixtures())
      assert_received {:fetched, _timeout}

      change(view, %{"search" => "cache"})

      refute_received {:fetched, _timeout}
    end

    test "an invalid timeout shows an error and keeps the previous value", %{conn: conn} do
      view = open(conn, [])
      assert_received {:fetched, _timeout}

      html = change(view, %{"timeout" => "999999"})
      assert html =~ "must be between"

      refresh(view)

      assert_received {:fetched, 5_000}
    end

    test "a stray validate without params is ignored", %{conn: conn} do
      view = open(conn, [])

      render_hook(view, "validate", %{"_target" => ["controls", "search"]})

      assert has_element?(view, "#ets-table-controls")
    end
  end

  describe "selection" do
    test "clicking a name opens the table in the details panel", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      view |> element(~s|#{row(cache)} td[data-column="name"] a|) |> render_click()

      assert_patch(view, table_path(cache))
      assert view |> element("#ets-table-details-name") |> render() =~ "MyApp.Cache"
      refute has_element?(view, "#ets-table-details[inert]")
      assert view |> element(row(cache)) |> render() =~ "bg-primary/5"
    end

    test "shows the metadata of the selected table", %{conn: conn} do
      tables = fixtures()
      cache = by_name(tables, MyApp.Cache)
      view = open(conn, tables, table_path(cache))

      panel = view |> element("#ets-table-details") |> render()

      assert panel =~ "ordered_set"
      assert panel =~ "public"
      assert panel =~ "900"
      assert panel =~ "1,048,576 B"
      assert panel =~ URI.encode_www_form(Formatters.format_pid(cache.owner))
    end

    test "resolves a bare name from the URL once the fetch lands", %{conn: conn} do
      view = open(conn, fixtures(), "#{@path}?table=ac_tab")

      assert view |> element("#ets-table-details-name") |> render() =~ ":ac_tab"
    end

    test "resolves an unnamed table by its reference string", %{conn: conn} do
      tables = fixtures()
      secrets = by_name(tables, :secrets)
      view = open(conn, tables, table_path(secrets))

      assert view |> element("#ets-table-details-name") |> render() =~ ":secrets"

      assert view |> element("#ets-table-details-table-id") |> render() |> text() =~
               inspect(secrets.id)
    end

    test "shows a skeleton until the first fetch lands", %{conn: conn} do
      stub_blocking(fixtures())

      {:ok, view, html} = live(conn, "#{@path}?table=ac_tab")

      assert html =~ "skeleton"
      refute html =~ "ets-table-details-not-found"

      render_hook(view, "restore_settings", %{})
      assert_receive {:fetching, fetch}
      send(fetch, :release)
      render_async(view)

      assert view |> element("#ets-table-details-name") |> render() =~ ":ac_tab"
    end

    test "reports a table the fetch does not have", %{conn: conn} do
      view = open(conn, fixtures(), "#{@path}?table=nope")

      assert has_element?(view, "#ets-table-details-not-found")
      assert view |> element("#ets-table-details-name") |> render() =~ "nope"
    end

    test "a selected table that disappears is reported after the refetch", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, "#{@path}?table=ac_tab")
      refute has_element?(view, "#ets-table-details-not-found")

      EtsFakes.stub_list(Enum.reject(tables, &(&1.name == :ac_tab)))
      refresh(view)

      assert has_element?(view, "#ets-table-details-not-found")
    end

    test "a private table carries a badge in the panel", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, table_path(by_name(tables, :secrets)))

      assert has_element?(view, "#ets-table-details-private-badge")
    end

    test "the panel keeps to the basics and links to the details page", %{conn: conn} do
      tables = fixtures()
      cache = by_name(tables, MyApp.Cache)
      view = open(conn, tables, table_path(cache))

      panel = view |> element("#ets-table-details") |> render()
      refute panel =~ "Key position"
      refute panel =~ "Peek records"
      assert has_element?(view, ~s|#ets-table-details-show-more[href="#{details_path(cache)}"]|)
    end

    test "closing the panel drops the param", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, table_path(by_name(tables, MyApp.Cache)))

      view |> element("#ets-table-details-close") |> render_click()

      assert_patch(view, @path)
      assert has_element?(view, "#ets-table-details[inert]")
      refute has_element?(view, "#ets-table-details-name")
    end

    test "explains an unresolved selection when the fetch failed", %{conn: conn} do
      EtsFakes.stub_error(:noconnection)
      {:ok, view, _html} = live(conn, "#{@path}?table=ac_tab")
      render_hook(view, "restore_settings", %{})
      render_async(view)

      assert has_element?(view, "#ets-table-details-unavailable")
    end
  end

  describe "error states" do
    test "reports an unreachable node", %{conn: conn} do
      EtsFakes.stub_error(:noconnection)
      {:ok, view, _html} = live(conn, @path)
      render_hook(view, "restore_settings", %{})
      render_async(view)

      assert has_element?(view, "#ets-tables-error")
      assert render(view) =~ "unreachable"
    end

    test "reports a timeout when there is nothing to fall back on", %{conn: conn} do
      EtsFakes.stub_error(:timeout)
      {:ok, view, _html} = live(conn, @path)
      render_hook(view, "restore_settings", %{})
      render_async(view)

      assert has_element?(view, "#ets-tables-error")
      assert render(view) =~ "timed out"
    end

    test "flashes a timeout rather than replacing the table", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      EtsFakes.stub_error(:timeout)
      refresh(view)

      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#ets-tables-error")
      assert has_element?(view, row(by_name(tables, MyApp.Cache)))
    end

    test "keeps the rows visible when a refetch fails", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      EtsFakes.stub_error(:noconnection)
      refresh(view)

      assert has_element?(view, "#ets-tables-error")
      assert has_element?(view, row(by_name(tables, MyApp.Cache)))
    end
  end

  describe "rate limiting" do
    test "a refused manual refresh tells the user to retry", %{conn: conn} do
      view = open(conn, [])

      Fakes.drain_rate_limiter()
      refresh(view)

      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#ets-tables-error")
    end

    test "a refused first fetch reports instead of loading forever", %{conn: conn} do
      EtsFakes.stub_list([])
      Fakes.drain_rate_limiter()

      {:ok, view, _html} = live(conn, @path)
      render_hook(view, "restore_settings", %{})
      render_async(view)

      # Nothing on screen to keep, so a flash alone would leave the table on
      # its loading text with no way to tell what happened.
      assert has_element?(view, "#ets-tables-error")
      refute has_element?(view, "#ets-tables-summary")
      refute render(view) =~ "Fetching tables"
    end

    test "a refused auto-refresh tick is silent and keeps the rows", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      Fakes.drain_rate_limiter()
      send(view.pid, :auto_refresh)
      render_async(view)

      refute has_element?(view, "#ets-tables-error")
      refute has_element?(view, "#flash-error")
      assert has_element?(view, row(by_name(tables, MyApp.Cache)))
    end
  end

  describe "columns picker" do
    test "shows the main columns by default and offers the rest", %{conn: conn} do
      view = open(conn, fixtures())

      assert has_element?(view, "#ets-table-controls-columns")
      assert has_element?(view, "#ets-table-controls-columns-heir-input")

      headers = view |> element("#ets-tables-table thead") |> render()

      for label <- ~w(Table Protection Type Objects Memory Owner) do
        assert headers =~ label
      end

      refute headers =~ "Heir"
    end

    test "an enabled extra column renders its metadata", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)
      cache = by_name(tables, MyApp.Cache)

      change(view, %{"columns" => ["heir", "keypos", "read_concurrency"]})

      headers = view |> element("#ets-tables-table thead") |> render()
      assert headers =~ "Heir"
      assert headers =~ "Keypos"

      row_id = EtsTablesLive.row_dom_id(cache.id)
      html = render(view)
      assert text(html) =~ "none"
      assert html =~ ~s|id="#{row_id}-heir-copy-text"|
      assert html =~ ~s|id="#{row_id}-keypos-copy-text"|
      assert html =~ ~s|id="#{row_id}-read_concurrency-copy-text"|
    end

    test "hiding a column takes it out of the table", %{conn: conn} do
      view = open(conn, fixtures())

      change(view, %{"columns" => ["type", "size", "owner"]})

      headers = view |> element("#ets-tables-table thead") |> render()
      refute headers =~ "Protection"
      assert headers =~ "Type"
      refute has_element?(view, ~s|td[data-column="protection"]|)
    end

    test "the name and memory columns cannot be deselected", %{conn: conn} do
      view = open(conn, fixtures())

      # The picker never offers them, so a change can only carry the others.
      change(view, %{"columns" => ["type"]})

      headers = view |> element("#ets-tables-table thead") |> render()
      assert headers =~ "Table"
      assert headers =~ "Memory"
      refute headers =~ "Owner"
    end

    test "protection and type are not sortable", %{conn: conn} do
      view = open(conn, fixtures())

      refute has_element?(view, ~s|button[phx-value-key="protection"]|)
      refute has_element?(view, ~s|button[phx-value-key="type"]|)
    end

    test "hiding the sorted column falls back to memory", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables)

      sort_by(view, "size")
      change(view, %{"columns" => ["protection", "type", "owner"]})

      assert view |> element(~s|th:has(button[phx-value-key="memory"])|) |> render() =~
               ~s|aria-sort="descending"|

      assert rendered_rows(view) ==
               rows_in_order(tables, [MyApp.Cache, :buffer, :ac_tab, :secrets])
    end

    test "stores and restores the chosen columns", %{conn: conn} do
      view = open(conn, fixtures())

      change(view, %{"columns" => ["type"]})
      assert_push_event(view, "store-settings", %{settings: %{"columns" => ["type"]}})

      render_hook(view, "restore_settings", %{"columns" => ["owner"]})

      headers = view |> element("#ets-tables-table thead") |> render()
      assert headers =~ "Owner"
      refute headers =~ "Type"
    end
  end

  describe "stored settings" do
    test "stores the validated controls for the next visit", %{conn: conn} do
      view = open(conn, [])

      change(view, %{"timeout" => "10000", "search" => "cache"})

      assert_push_event(view, "store-settings", %{settings: settings})
      assert settings["timeout"] == "10000"
      assert settings["search"] == "cache"
    end

    test "stores the page size alongside the controls", %{conn: conn} do
      view = open(conn, fixtures())

      view
      |> element("#ets-tables-pager-page-size-form")
      |> render_change(%{"page_size" => "50"})

      assert_push_event(view, "store-settings", %{settings: settings})
      assert settings["page_size"] == "50"
    end

    test "restores the stored search and page size with the single first fetch", %{conn: conn} do
      tables = Enum.map(1..30, &EtsFakes.table(name: :"t#{&1}", memory: (100 - &1) * 8))
      view = open(conn, tables, @path, %{"page_size" => "10", "search" => "t1"})

      # t1 and t10..t19 match, over pages of ten.
      assert render(view) =~ "1 / 2"
      assert_received {:fetched, _timeout}
      refute_received {:fetched, _timeout}
    end
  end

  describe "row_dom_id/1" do
    test "keeps apart tables whose names only differ in dropped characters" do
      assert EtsTablesLive.row_dom_id(:"my table") != EtsTablesLive.row_dom_id(:"my-table")
    end

    test "stays clear of the page's own ids" do
      refute EtsTablesLive.row_dom_id(:tables) in ["ets-tables", "ets-tables-page"]
      refute EtsTablesLive.row_dom_id(:"tables-page") in ["ets-tables", "ets-tables-page"]
    end

    test "is stable for a reference" do
      ref = make_ref()

      assert EtsTablesLive.row_dom_id(ref) == EtsTablesLive.row_dom_id(ref)
      assert EtsTablesLive.row_dom_id(ref) != EtsTablesLive.row_dom_id(make_ref())
    end
  end

  describe "hostile input" do
    test "an unknown sort key is ignored", %{conn: conn} do
      view = open(conn, fixtures())

      render_hook(view, "sort", %{"key" => "nope_not_an_atom_123"})

      assert has_element?(view, "#ets-tables-table")
    end

    test "an interval outside the offered options is ignored", %{conn: conn} do
      view = open(conn, [])

      for value <- ~w(-5 0 1 2000 nonsense) do
        render_hook(view, "set_interval", %{"interval" => value})
      end

      assert has_element?(view, "#ets-tables-refresh-interval")
    end

    test "a null search from localStorage is survivable", %{conn: conn} do
      view = open(conn, [])

      render_hook(view, "restore_settings", %{"search" => nil})

      assert has_element?(view, "#ets-table-controls")
    end

    test "an empty table param opens nothing", %{conn: conn} do
      view = open(conn, fixtures(), "#{@path}?table=")

      assert has_element?(view, "#ets-table-details[inert]")
    end
  end
end
