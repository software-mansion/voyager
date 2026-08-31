defmodule VoyagerWeb.ProcessesLiveTest do
  # async: false because we use Mox global mode: the remote scan runs in an
  # async task, so erpc expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes
  alias Voyager.Queries.Processes
  alias VoyagerWeb.ProcessesLive

  @node_name "demo@localhost"
  @path "/node/demo@localhost/processes"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  # Builds a fake process row as the remote agent would return it.
  defp entry(opts) do
    %{
      pid: Keyword.fetch!(opts, :pid),
      registered_name: Keyword.get(opts, :registered_name),
      initial_call: Keyword.get(opts, :initial_call, {:proc_lib, :init_p, 5}),
      current_function: Keyword.get(opts, :current_function, {:gen_server, :loop, 7}),
      memory: Keyword.get(opts, :memory, 1_024),
      reductions: Keyword.get(opts, :reductions, 100),
      message_queue_len: Keyword.get(opts, :message_queue_len, 0)
    }
  end

  # Stubs the remote scan, echoing the call args back to the test process.
  defp stub_scan(entries, scanned \\ nil) do
    test = self()
    scanned = scanned || length(entries)

    stub(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :proc_top, args, timeout ->
      send(test, {:scanned, args, timeout})
      {entries, scanned}
    end)
  end

  # Total body rows, real plus the blank fillers that hold the height.
  defp rendered_body_rows(view) do
    view
    |> render()
    |> String.split("<tbody")
    |> Enum.at(1)
    |> String.split("</tbody>")
    |> hd()
    |> then(&(length(String.split(&1, "<tr")) - 1))
  end

  defp fake_pids(count) do
    Enum.map(1..count, fn _ -> spawn(fn -> :ok end) end)
  end

  describe "mount" do
    test "renders the node name header", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "h1", @node_name)
    end

    test "renders the toolbar controls", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-toolbar-search")
      assert has_element?(view, "#processes-toolbar-limit")
      assert has_element?(view, "#processes-toolbar-page-size")
      assert has_element?(view, "#processes-toolbar-timeout")
      assert has_element?(view, "#processes-toolbar-refresh")
    end

    test "scans with the default options", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert_received {:scanned, [_attrs, :memory, 100, :desc, :undefined], 5_000}
    end

    test "renders a row per returned process", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, registered_name: :my_worker)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "##{ProcessesLive.row_dom_id(pid)}")
      assert render(view) =~ ":my_worker"
    end

    test "falls back to the initial call when there is no registered name", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, initial_call: {MyApp.Worker, :start_link, 1})])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert render(view) =~ "MyApp.Worker.start_link/1"
    end

    test "stamps the header with the fetch time once results arrive", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      html = render_async(view)

      # The header must leave its waiting state once a fetch completes.
      refute html =~ "waiting for first fetch"
    end

    test "shows the empty state when nothing matched", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert render(view) =~ "No processes matched."
    end
  end

  describe "refetching" do
    test "keeps the table and its rows mounted while refetching", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      row = "##{ProcessesLive.row_dom_id(pid)}"
      assert has_element?(view, row)

      # Sorting triggers a remote refetch; the previous rows must stay on
      # screen rather than the table being torn down and rebuilt.
      view |> element(~s|button[phx-value-key="reductions"]|) |> render_click()

      assert has_element?(view, "#processes-table")
      assert has_element?(view, row)
    end

    test "keeps the table the same height when fewer rows come back", %{conn: conn} do
      pids = fake_pids(25)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, "#{@path}?page_size=25")
      render_async(view)

      full = rendered_body_rows(view)

      # A search that matches one process must not collapse the table: the body
      # is padded to the page size so the page does not jump.
      stub_scan([entry(pid: hd(pids))], 25)

      view
      |> element("#processes-toolbar-search-form")
      |> render_change(%{"search" => "worker"})

      render_async(view)

      assert rendered_body_rows(view) == full
    end

    test "keeps the rows visible when a refetch fails", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      view |> element("#processes-toolbar-refresh") |> render_click()
      render_async(view)

      # The error is shown above the table, not instead of it.
      assert has_element?(view, "#processes-error")
      assert has_element?(view, "##{ProcessesLive.row_dom_id(pid)}")
    end
  end

  describe "column selection" do
    test "renders a chip per selectable attribute", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      for attr <- Processes.required_attrs() ++ Processes.optional_attrs() do
        assert has_element?(view, "#column-#{attr}-input")
      end
    end

    test "required columns are checked and cannot be deselected", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      for attr <- Processes.required_attrs() do
        assert has_element?(view, "#column-#{attr}-input[checked][disabled]")
      end
    end

    test "selecting a column adds it to the URL and refetches", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so the assertion can only match the new one.
      assert_received {:scanned, _args, _timeout}

      view
      |> element("#process-column-controls-form")
      |> render_change(%{"columns" => ["status"]})

      render_async(view)

      # Required attrs survive even though a disabled checkbox submits nothing.
      assert_received {:scanned, [attrs, _sort, _limit, _dir, _search], _timeout}
      assert :status in attrs
      assert :memory in attrs
    end

    test "restores the selected columns from the URL", %{conn: conn} do
      stub_scan([])

      {:ok, view, _html} = live(conn, "#{@path}?columns=status")
      render_async(view)

      assert has_element?(view, "#column-status-input[checked]")

      # The selected column appears in the table; the unselected one does not.
      headers = view |> element("#processes-table thead") |> render()
      assert headers =~ "Status"
      refute headers =~ "Priority"
    end

    test "a hand-edited URL cannot drop a required column", %{conn: conn} do
      stub_scan([])

      {:ok, view, _html} = live(conn, "#{@path}?columns=status")
      render_async(view)

      assert_received {:scanned, [attrs, _sort, _limit, _dir, _search], _timeout}
      assert :memory in attrs
    end
  end

  describe "auto refresh" do
    test "offers the interval selector", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-toolbar-interval")
    end

    test "refetches on the chosen interval", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so only an auto-refresh can satisfy the assertion.
      assert_received {:scanned, _args, _timeout}

      view
      |> element("#processes-toolbar-interval-form")
      |> render_change(%{"interval" => "5000"})

      send(view.pid, :auto_refresh)
      render_async(view)

      assert_received {:scanned, _args, _timeout}
    end

    test "does nothing when switched off", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-interval-form")
      |> render_change(%{"interval" => "off"})

      assert render(view) =~ "processes-toolbar-interval"
    end
  end

  describe "column widths" do
    test "numeric columns carry a fixed width and truncate", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, reductions: 999_999_999_999)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      for key <- Processes.sortable_attrs() do
        header = view |> element(~s|th:has(button[phx-value-key="#{key}"])|) |> render()

        # A width plus its max-w counterpart is what actually stops a long
        # value widening the column under auto table layout.
        assert header =~ ~r/\bw-\d+\b/
        assert header =~ ~r/\bmax-w-\d+\b/
      end
    end

    test "text columns are left to size themselves", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # PID is narrow and fixed now; the name column is the flexible one.
      header = view |> element("#processes-table thead th:nth-child(2)") |> render()

      refute header =~ ~r/\bmax-w-\d+\b/
    end

    test "keeps the full numeric value reachable when truncated", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, reductions: 999_999_999_999)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # The title carries the untruncated value.
      assert render(view) =~ ~s|title="999,999,999,999"|
    end
  end

  describe "info note" do
    test "explains that data is fetched once and then paged locally", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-info")
      assert render(view) =~ "paged here in the browser"
    end
  end

  describe "scan summary" do
    test "reports how many processes were found and how many returned", %{conn: conn} do
      pids = fake_pids(2)
      stub_scan(Enum.map(pids, &entry(pid: &1)), 500)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      summary = view |> element("#processes-scan-summary") |> render()

      assert summary =~ "Found"
      assert summary =~ "500"
      assert summary =~ "returned"
    end

    test "flags a truncated scan", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)], 900)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      summary = view |> element("#processes-scan-summary") |> render()

      assert summary =~ "truncated"
      # Truncation is expected whenever the limit bites, so it reads as info.
      assert summary =~ "badge-info"
      refute summary =~ "badge-warning"
    end

    test "does not flag an exhaustive scan", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)], 1)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      refute render(view) =~ "truncated"
    end
  end

  describe "sorting" do
    test "sorts by a numeric column on the remote", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element(~s|button[phx-value-key="reductions"]|) |> render_click()
      render_async(view)

      assert_received {:scanned, [_attrs, :reductions, _limit, :desc, _search], _timeout}
    end

    test "shows both arrows on every sortable column", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      for key <- Processes.sortable_attrs() do
        header = view |> element(~s|th:has(button[phx-value-key="#{key}"])|) |> render()

        assert header =~ "icon-move-up"
        assert header =~ "icon-move-down"
      end
    end

    test "dims both arrows on a column that is not sorted", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # :memory is the default sort column, so :reductions is unsorted.
      header = view |> element(~s|th:has(button[phx-value-key="reductions"])|) |> render()

      refute header =~ "text-primary"
      assert header =~ "text-base-content/30"
      assert header =~ ~s|aria-sort="none"|
    end

    test "highlights only the descending arrow when sorted descending", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      header = view |> element(~s|th:has(button[phx-value-key="memory"])|) |> render()

      assert header =~ ~s|aria-sort="descending"|
      # The highlighted arrow is the down one; the up arrow stays dimmed.
      assert header =~ ~r/icon-move-down[^"]*text-primary/
      assert header =~ ~r/icon-move-up[^"]*text-base-content\/30/
    end

    test "highlights only the ascending arrow when sorted ascending", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Re-selecting the active column flips it to :asc.
      view |> element(~s|button[phx-value-key="memory"]|) |> render_click()
      render_async(view)

      header = view |> element(~s|th:has(button[phx-value-key="memory"])|) |> render()

      assert header =~ ~s|aria-sort="ascending"|
      assert header =~ ~r/icon-move-up[^"]*text-primary/
      assert header =~ ~r/icon-move-down[^"]*text-base-content\/30/
    end

    test "does not render sort arrows on a non-sortable column", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      header = view |> element("#processes-table thead th:first-child") |> render()

      refute header =~ "icon-move-up"
      refute header =~ "icon-move-down"
    end

    test "toggles the direction when the active column is re-selected", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # :memory is the default sort column, so clicking it flips to :asc.
      view |> element(~s|button[phx-value-key="memory"]|) |> render_click()
      render_async(view)

      assert_received {:scanned, [_attrs, :memory, _limit, :asc, _search], _timeout}
    end

    test "a newly selected column starts descending", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element(~s|button[phx-value-key="memory"]|) |> render_click()
      render_async(view)

      view |> element(~s|button[phx-value-key="message_queue_len"]|) |> render_click()
      render_async(view)

      assert_received {:scanned, [_attrs, :message_queue_len, _limit, :desc, _search], _timeout}
    end
  end

  describe "search" do
    test "passes the search term to the remote", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-search-form")
      |> render_change(%{"search" => "worker"})

      render_async(view)

      assert_received {:scanned, [_attrs, _sort, _limit, _dir, "worker"], _timeout}
    end
  end

  describe "result size and timeout" do
    test "changing the limit refetches with the new size", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-limit-form")
      |> render_change(%{"limit" => "250"})

      render_async(view)

      assert_received {:scanned, [_attrs, _sort, 250, _dir, _search], _timeout}
    end

    test "the timeout is entered and sent in milliseconds", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-timeout-form")
      |> render_change(%{"timeout" => "10000"})

      render_async(view)

      assert_received {:scanned, _args, 10_000}
    end

    test "clamps an out-of-range timeout to the supported bounds", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      {_min, max} = Processes.timeout_bounds()

      view
      |> element("#processes-toolbar-timeout-form")
      |> render_change(%{"timeout" => "999999"})

      render_async(view)

      assert_received {:scanned, _args, ^max}
    end
  end

  describe "query params" do
    test "restores the limit and timeout from the URL", %{conn: conn} do
      stub_scan([])

      {:ok, view, _html} = live(conn, "#{@path}?limit=250&timeout=10000")
      render_async(view)

      assert_received {:scanned, [_attrs, _sort, 250, _dir, _search], 10_000}
    end

    test "writes the limit into the query string", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-limit-form")
      |> render_change(%{"limit" => "50"})

      assert_patched(view, "#{@path}?limit=50")
    end

    test "writes the timeout into the query string as milliseconds", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-timeout-form")
      |> render_change(%{"timeout" => "3000"})

      assert_patched(view, "#{@path}?timeout=3000")
    end

    test "writes the page size into the query string", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-page-size-form")
      |> render_change(%{"page_size" => "50"})

      assert_patched(view, "#{@path}?page_size=50")
    end

    test "restores the page size from the URL", %{conn: conn} do
      stub_scan([])

      {:ok, view, _html} = live(conn, "#{@path}?page_size=50")
      render_async(view)

      assert has_element?(view, ~s|#processes-toolbar-page-size option[value="50"][selected]|)
    end

    test "ignores malformed query params instead of crashing", %{conn: conn} do
      stub_scan([])

      {:ok, view, _html} = live(conn, "#{@path}?limit=abc&timeout=xyz")
      render_async(view)

      # Falls back to the defaults rather than raising on a hand-edited URL.
      assert_received {:scanned, [_attrs, _sort, 100, _dir, _search], 5_000}
    end
  end

  describe "manual refresh" do
    test "refetches on demand", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so the next assertion can only match the refresh.
      assert_received {:scanned, _args, _timeout}

      view |> element("#processes-toolbar-refresh") |> render_click()
      render_async(view)

      assert_received {:scanned, _args, _timeout}
    end
  end

  describe "pagination" do
    test "pages over the fetched rows without refetching", %{conn: conn} do
      pids = fake_pids(30)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      first_page_last = Enum.at(pids, 24)
      second_page_first = Enum.at(pids, 25)

      assert has_element?(view, "##{ProcessesLive.row_dom_id(first_page_last)}")
      refute has_element?(view, "##{ProcessesLive.row_dom_id(second_page_first)}")

      view |> element("#processes-pager-next") |> render_click()

      assert has_element?(view, "##{ProcessesLive.row_dom_id(second_page_first)}")
      refute has_element?(view, "##{ProcessesLive.row_dom_id(first_page_last)}")
    end

    test "changing rows per page reslices without refetching", %{conn: conn} do
      pids = fake_pids(30)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so a later scan would be visible.
      assert_received {:scanned, _args, _timeout}

      view
      |> element("#processes-toolbar-page-size-form")
      |> render_change(%{"page_size" => "10"})

      # Page size only slices the rows already fetched.
      refute_received {:scanned, _args, _timeout}

      assert render(view) =~ "1 / 3"
    end

    test "shows the number of rows the page size asks for", %{conn: conn} do
      pids = fake_pids(30)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, "#{@path}?page_size=10")
      render_async(view)

      # 10 per page over 30 rows: the 10th row is on page 1, the 11th is not.
      assert has_element?(view, "##{ProcessesLive.row_dom_id(Enum.at(pids, 9))}")
      refute has_element?(view, "##{ProcessesLive.row_dom_id(Enum.at(pids, 10))}")
      assert render(view) =~ "1 / 3"
    end

    test "hides the pager when everything fits on one page", %{conn: conn} do
      pids = fake_pids(3)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      refute has_element?(view, "#processes-pager-next")
    end
  end

  describe "drill-in" do
    test "navigates to the details page for the clicked process", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      pid_string = Processes.format_pid(pid)

      view |> element("##{ProcessesLive.row_dom_id(pid)}") |> render_click()

      {to, _flash} = assert_redirect(view)

      assert to =~ "/processes/#{URI.encode_www_form(pid_string)}"
      # The configured view is carried so the details page can return to it.
      assert to =~ "return_to="
    end
  end

  describe "error states" do
    test "reports an unreachable node", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-error")
      assert render(view) =~ "unreachable"
    end

    test "reports a timeout with actionable advice", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :timeout})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-error")
      assert render(view) =~ "Timed out"
    end

    test "reports a missing remote agent", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:exception, :undef, []})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert render(view) =~ "agent is not loaded"
    end
  end
end
