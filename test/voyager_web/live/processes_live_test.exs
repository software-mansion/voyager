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

    test "shows the empty state when nothing matched", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert render(view) =~ "No processes matched."
    end
  end

  describe "scan summary" do
    test "reports how many processes were ranked out of those scanned", %{conn: conn} do
      pids = fake_pids(2)
      stub_scan(Enum.map(pids, &entry(pid: &1)), 500)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#processes-scan-summary")
      assert render(view) =~ "500"
    end

    test "flags a truncated scan", %{conn: conn} do
      [pid] = fake_pids(1)
      stub_scan([entry(pid: pid)], 900)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert render(view) =~ "truncated"
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

    test "the timeout applies to the next scan", %{conn: conn} do
      stub_scan([])
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#processes-toolbar-timeout-form")
      |> render_change(%{"timeout" => "10000"})

      view |> element("#processes-toolbar-refresh") |> render_click()
      render_async(view)

      assert_received {:scanned, _args, 10_000}
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

      assert_redirect(
        view,
        "/node/#{URI.encode_www_form(@node_name)}/processes/#{URI.encode_www_form(pid_string)}"
      )
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
