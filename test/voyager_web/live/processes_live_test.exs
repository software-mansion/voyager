defmodule VoyagerWeb.ProcessesLiveTest do
  # async: false because we use Mox global mode: the remote scan runs in an
  # async task, so erpc expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes
  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.ProcessComponents
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

  defp change(view, attrs) do
    view |> element("#process-controls") |> render_change(%{"controls" => attrs})
  end

  defp refresh(view) do
    view |> element("#processes-refresh-interval-refresh-now-button") |> render_click()
    render_async(view)
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

      assert has_element?(view, "#controls_search")
      assert has_element?(view, "#controls_limit")
      assert has_element?(view, "#controls_timeout")
      assert has_element?(view, "#processes-refresh-interval-refresh-now-button")
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

    test "renders the name and initial call as separate columns", %{conn: conn} do
      [pid] = fake_pids(1)

      stub_scan([
        entry(pid: pid, registered_name: :my_worker, initial_call: {MyApp.Worker, :start_link, 1})
      ])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      row = view |> element("##{ProcessesLive.row_dom_id(pid)}") |> render()

      assert row =~ ~s|data-column="registered_name"|
      assert row =~ ~s|data-column="initial_call"|
      assert row =~ ":my_worker"
      assert row =~ "MyApp.Worker.start_link/1"
    end

    test "shows a placeholder when a process has no registered name", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, registered_name: [])])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # The columns are independent now: an unregistered process leaves the
      # name blank rather than borrowing its initial call.
      assert view |> element(~s|td[data-column="registered_name"]|) |> render() =~ "—"
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

    test "renders only the rows that came back", %{conn: conn} do
      pids = fake_pids(25)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, "#{@path}?page_size=25")
      render_async(view)

      assert rendered_body_rows(view) == 25

      # A filtering search shrinks the table rather than padding it out.
      stub_scan([entry(pid: hd(pids))], 25)

      change(view, %{"search" => "worker"})
      refresh(view)

      assert rendered_body_rows(view) == 1
    end

    test "keeps the rows visible when a refetch fails", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      view |> element("#processes-refresh-interval-refresh-now-button") |> render_click()
      render_async(view)

      # The error is shown above the table, not instead of it.
      assert has_element?(view, "#processes-error")
      assert has_element?(view, "##{ProcessesLive.row_dom_id(pid)}")
    end
  end

  describe "PID cell" do
    test "links to the details page, carrying the list's params", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, "#{@path}?page_size=50")
      render_async(view)

      link = view |> element(~s|td[data-column="pid"] a|) |> render()

      assert link =~ URI.encode_www_form(Processes.format_pid(pid))
      # Reads as a link on hover.
      assert link =~ "hover:underline"
    end

    test "only the pid navigates", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, registered_name: :my_worker)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      row = view |> element("##{ProcessesLive.row_dom_id(pid)}") |> render()

      # The row itself is not clickable, and no other cell holds a link.
      refute row =~ "phx-click=\"select-process\""
      assert row |> String.split("<a ") |> length() == 2
    end

    test "an empty value says so instead of offering an em dash to copy", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, registered_name: [])])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      row_id = ProcessesLive.row_dom_id(pid)
      html = render(view)

      assert html =~ "Not set"
      # No copy affordance for a value that is not there.
      refute html =~ ~s|id="#{row_id}-name-copy"|
    end

    test "every cell offers a tooltip with a copy button", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid, registered_name: :my_worker)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      row_id = ProcessesLive.row_dom_id(pid)
      html = render(view)

      # Not just the pid: each value is reachable and copyable in full.
      for suffix <- ~w(pid name initial-call memory reductions msgq) do
        assert html =~ ~s|id="#{row_id}-#{suffix}|
      end

      assert html =~ ~s|id="#{row_id}-memory-copy"|
      assert html =~ ~s|id="#{row_id}-memory-copy-text"|
    end
  end

  describe "auto refresh" do
    test "offers the interval selector", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-refresh-interval")
    end

    test "refetches on the chosen interval", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so only an auto-refresh can satisfy the assertion.
      assert_received {:scanned, _args, _timeout}

      view
      |> element("#processes-refresh-interval-form")
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
      |> element("#processes-refresh-interval-form")
      |> render_change(%{"interval" => "off"})

      assert has_element?(view, "#processes-refresh-interval")
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

      row_id = ProcessesLive.row_dom_id(pid)

      # The tooltip's copy source carries the untruncated value.
      html = render(view)
      assert html =~ ~s|id="#{row_id}-reductions-copy-text"|
      assert html =~ "999,999,999,999"
    end
  end

  describe "scan summary" do
    test "reports how many processes were fetched out of those scanned", %{conn: conn} do
      pids = fake_pids(2)
      stub_scan(Enum.map(pids, &entry(pid: &1)), 500)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      summary = view |> element("#processes-scan-summary") |> render()

      assert summary =~ "Fetched"
      assert summary =~ "out of"
      assert summary =~ "500"
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

  describe "controls form" do
    test "renders one form over every control", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#process-controls")
      assert has_element?(view, "#controls_search")
      assert has_element?(view, "#controls_limit")
      assert has_element?(view, "#controls_timeout")
      assert has_element?(view, "#process-controls-columns")
    end

    test "changing the form does not refetch immediately", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan; nothing after this should produce another.
      assert_received {:scanned, _args, _timeout}

      change(view, %{"limit" => "250", "timeout" => "10000", "search" => "worker"})

      refute_received {:scanned, _args, _timeout}
    end

    test "the validated values reach the next fetch", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert_received {:scanned, _args, _timeout}

      change(view, %{"limit" => "250", "timeout" => "10000", "search" => "worker"})
      refresh(view)

      assert_received {:scanned, [_attrs, _sort, 250, _dir, "worker"], 10_000}
    end

    test "an invalid value shows an error and is not used", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert_received {:scanned, _args, _timeout}

      html = change(view, %{"timeout" => "999999"})
      assert html =~ "must be between"

      refresh(view)

      # The previous valid timeout is what actually gets used.
      assert_received {:scanned, _args, 5_000}
    end

    test "a stray validate without params is ignored", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # As sent by a debounced input firing after a form patch.
      render_hook(view, "validate", %{"_target" => ["controls", "search"]})

      assert has_element?(view, "#process-controls")
    end

    test "a control change refetches after the debounce window", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert_received {:scanned, _args, _timeout}

      change(view, %{"limit" => "250"})
      # Not yet: the debounce window is still open.
      refute_received {:scanned, _args, _timeout}

      # The window elapsing delivers :refetch.
      send(view.pid, :refetch)
      render_async(view)

      assert_received {:scanned, [_attrs, _sort, 250, _dir, _search], _timeout}
    end

    test "shows the round trip of the last fetch", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert view |> element("#processes-scan-summary") |> render() =~ "ms"
    end

    test "has no round trip before the first fetch lands", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> :erlang.error({:erpc, :timeout}) end)
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # A failed fetch has no scan summary at all, so no round trip either.
      refute has_element?(view, "#processes-scan-summary")
    end

    test "locks the UI only for control-triggered fetches", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Auto/manual refresh stays quiet: no dim, no disable.
      refute has_element?(view, "#process-controls fieldset[disabled]")

      # The debounce window itself stays undimmed — the user is still editing.
      change(view, %{"limit" => "250"})
      refute render(view) =~ "pointer-events-none select-none opacity-60"

      # The dim spans the control-triggered fetch and clears when it lands.
      send(view.pid, :refetch)
      render_async(view)
      refute render(view) =~ "pointer-events-none select-none opacity-60"
    end

    test "column changes apply only once their fetch lands", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      change(view, %{"columns" => ["status"]})

      # Still the old columns: the data on screen was fetched without :status.
      refute view |> element("#processes-table thead") |> render() =~ "Status"

      send(view.pid, :refetch)
      render_async(view)

      headers = view |> element("#processes-table thead") |> render()
      assert headers =~ "Status"
      refute headers =~ "Reductions"
    end

    test "required columns cannot be deselected", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      change(view, %{"columns" => []})

      headers = view |> element("#processes-table thead") |> render()
      assert headers =~ "PID"
      assert headers =~ "Memory"
    end

    test "stores the validated settings for the next visit", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      change(view, %{"limit" => "250"})

      assert_push_event(view, "store-settings", %{settings: settings})
      assert settings["limit"] == "250"
    end

    test "stores the page size alongside the fetch options", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-pager-page-size-form")
      |> render_change(%{"page_size" => "50"})

      assert_push_event(view, "store-settings", %{settings: settings})
      assert settings["page_size"] == "50"
    end

    test "restores the stored page size", %{conn: conn} do
      pids = fake_pids(30)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      render_hook(view, "restore_settings", %{"page_size" => "10"})
      render_async(view)

      assert render(view) =~ "1 / 3"
    end

    test "restores stored settings and fetches with them", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert_received {:scanned, _args, _timeout}

      render_hook(view, "restore_settings", %{"limit" => "500", "search" => "hog"})
      render_async(view)

      assert_received {:scanned, [_attrs, _sort, 500, _dir, "hog"], _timeout}
    end
  end

  describe "rate limiting" do
    # Empties both buckets on the app's limiter, restoring them afterwards.
    defp drain_limiter do
      limiter = Voyager.Services.RateLimiter
      previous = :sys.get_state(limiter)
      :sys.replace_state(limiter, fn state -> %{state | tokens_high: 0, tokens_low: 0} end)
      on_exit(fn -> :sys.replace_state(limiter, fn _ -> previous end) end)
    end

    test "a refused manual refresh tells the user to retry", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      drain_limiter()
      view |> element("#processes-refresh-interval-refresh-now-button") |> render_click()
      render_async(view)

      # Transient, so it flashes and leaves the table alone.
      assert render(view) =~ "Try again in"
      refute has_element?(view, "#processes-error")
    end

    test "a refused auto-refresh tick is silent and keeps the rows", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      drain_limiter()
      send(view.pid, :auto_refresh)
      render_async(view)

      refute has_element?(view, "#processes-error")
      assert has_element?(view, "##{ProcessesLive.row_dom_id(pid)}")
    end
  end

  describe "manual refresh" do
    test "refetches on demand", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      # Drop the mount scan so the next assertion can only match the refresh.
      assert_received {:scanned, _args, _timeout}

      view |> element("#processes-refresh-interval-refresh-now-button") |> render_click()
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
      |> element("#processes-pager-page-size-form")
      |> render_change(%{"page_size" => "10"})

      # Page size only slices the rows already fetched.
      refute_received {:scanned, _args, _timeout}

      assert render(view) =~ "1 / 3"
    end

    test "shows the number of rows the page size asks for", %{conn: conn} do
      pids = fake_pids(30)
      stub_scan(Enum.map(pids, &entry(pid: &1)))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-pager-page-size-form")
      |> render_change(%{"page_size" => "10"})

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
    test "the pid link points at the details page", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)])

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      pid_string = Processes.format_pid(pid)
      href = view |> element(~s|td[data-column="pid"] a|) |> render()

      assert href =~ "/processes/#{URI.encode_www_form(pid_string)}"
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
