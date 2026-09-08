defmodule VoyagerWeb.EtsTableLiveTest do
  # async: false because Mox global mode: the metadata and record reads run in
  # async tasks, so expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @table "cache_table"
  @path "/node/demo@localhost/ets-tables/cache_table"
  @budget Voyager.Agent.default_budget()

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  describe "metadata" do
    test "renders the table name and the info panel", %{conn: conn} do
      stub_info()

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#ets-table-name", @table)
      assert has_element?(view, "#ets-table-info")
      assert has_element?(view, "#ets-info-keypos", "1")
    end

    test "resolves an unnamed table from its reference in the URL", %{conn: conn} do
      test = self()
      ref = make_ref()

      stub(Voyager.ErpcMock, :call, fn
        _node, :ets, :all, [], _timeout ->
          [ref]

        _node, :ets, :info, [id], _timeout ->
          send(test, {:info, id})
          Keyword.put(table_info([]), :named_table, false)

        _node, :erlang, :system_info, [:wordsize], _timeout ->
          8
      end)

      {:ok, view, _html} = live(conn, ref_path(ref))
      render_async(view)

      assert_received {:info, ^ref}
      assert has_element?(view, "#ets-table-info")
      refute has_element?(view, "#ets-table-error")
    end

    test "shows an error when the referenced table no longer exists", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn
        _node, :ets, :all, [], _timeout -> []
      end)

      {:ok, view, _html} = live(conn, ref_path(make_ref()))
      render_async(view)

      assert has_element?(view, "#ets-table-error", "No such table")
    end

    test "shows an error when the table is gone", %{conn: conn} do
      stub_erpc(fn
        _node, :erlang, :list_to_existing_atom, _args, _timeout -> String.to_atom(@table)
        _node, :ets, :info, _args, _timeout -> :undefined
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#ets-table-error", "No such table")
    end

    test "disables the fetch button for a private table", %{conn: conn} do
      stub_info(protection: :private)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#ets-private-notice")
      assert has_element?(view, "#ets-peek-fetch[disabled]")
    end
  end

  describe "gating" do
    test "reads no records until the button is clicked", %{conn: conn} do
      stub_info()

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      refute has_element?(view, "#ets-records")
      refute has_element?(view, "#ets-truncation-notice")
      assert has_element?(view, "#ets-peek-fetch", "Fetch records")
    end

    test "fetches a page on click and lists one-line previews", %{conn: conn} do
      stub_info()
      stub_select(ok_chunk([{:a, 1}, {:b, 2}]))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records")
      assert has_element?(view, "#ets-records-0-toggle", "{:a, 1}")
      assert has_element?(view, "#ets-records-count", "2 records")
      refute has_element?(view, "#ets-truncation-notice")
    end

    test "shows the truncation notice only when the agent shortened a record", %{conn: conn} do
      stub_info()
      stub_select(ok_chunk([{:a, 1}], :undefined, true))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-truncation-notice")
    end

    test "sends the selected page size, budget and timeout to the agent", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, args, timeout ->
        send(test, {:called, args, timeout})
        ok_chunk([])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#ets-peek-controls")
      |> render_change(%{"peek" => %{"chunk_size" => "50", "timeout" => "2000"}})

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, [_table, 50, @budget, :undefined], 2_000}
    end

    test "sends an edited budget to the agent", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, args, _timeout ->
        send(test, {:called, args})
        ok_chunk([])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#ets-peek-controls")
      |> render_change(%{"peek" => %{"budget" => "300"}})

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, [_table, _limit, 300, :undefined]}
    end

    test "keeps the previous page size when an edit is invalid", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, args, _timeout ->
        send(test, {:called, args})
        ok_chunk([])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#ets-peek-controls")
      |> render_change(%{"peek" => %{"chunk_size" => "10", "timeout" => "999999"}})

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, [_table, 10, @budget, :undefined]}
    end
  end

  describe "pagination" do
    test "next passes the continuation and replaces the page", %{conn: conn} do
      test = self()
      cont = {:ets_cont, 1}
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, _limit, _budget, continuation], _timeout ->
        send(test, {:called, continuation})

        case continuation do
          :undefined -> ok_chunk([{:a, 1}], cont)
          ^cont -> ok_chunk([{:b, 2}])
        end
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-pager", "1 / 2")
      assert has_element?(view, "#ets-records-0-toggle", "{:a, 1}")
      refute has_element?(view, "#ets-pager-next[disabled]")

      view |> element("#ets-pager-next") |> render_click()
      render_async(view)

      assert_received {:called, :undefined}
      assert_received {:called, ^cont}
      assert has_element?(view, "#ets-pager", "2 / 2")
      assert has_element?(view, "#ets-records-0-toggle", "{:b, 2}")
      refute has_element?(view, "#ets-records-0-toggle", "{:a, 1}")
      assert has_element?(view, "#ets-pager-next[disabled]")
    end

    test "previous re-runs the select from the stored continuation", %{conn: conn} do
      test = self()
      cont = {:ets_cont, 1}
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, _limit, _budget, continuation], _timeout ->
        send(test, {:called, continuation})

        case continuation do
          :undefined -> ok_chunk([{:a, 1}], cont)
          ^cont -> ok_chunk([{:b, 2}])
        end
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      view |> element("#ets-pager-next") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-pager-prev")
      view |> element("#ets-pager-prev") |> render_click()
      render_async(view)

      assert_received {:called, :undefined}
      assert_received {:called, ^cont}
      assert_received {:called, :undefined}
      assert has_element?(view, "#ets-pager", "1 / 2")
      assert has_element?(view, "#ets-records-0-toggle", "{:a, 1}")
      assert has_element?(view, "#ets-pager-prev[disabled]")
    end

    test "reload snapshot starts a new select rather than resuming", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, _limit, _budget, continuation], _timeout ->
        send(test, {:called, continuation})
        ok_chunk([{:a, 1}], {:ets_cont, 1})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      assert_received {:called, :undefined}

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, :undefined}
      assert has_element?(view, "#ets-pager", "1 / 2")
    end

    test "a new page size restarts the walk with the new limit", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, limit, _budget, continuation], _timeout ->
        send(test, {:called, limit, continuation})
        ok_chunk([{:a, 1}], {:ets_cont, 1})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      assert_received {:called, 10, :undefined}

      view
      |> element("#ets-pager-page-size-form")
      |> render_change(%{"page_size" => "50"})

      render_async(view)
      assert_received {:called, 50, :undefined}
    end
  end

  describe "expanding a record" do
    test "opens the term inspector for that row", %{conn: conn} do
      stub_info()
      stub_select(ok_chunk([{:a, 1}]))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      refute has_element?(view, "#ets-records-0-term")
      view |> element("#ets-records-0-toggle") |> render_click()
      assert has_element?(view, "#ets-records-0-term")

      view |> element("#ets-records-0-toggle") |> render_click()
      refute has_element?(view, "#ets-records-0-term")
    end

    test "renders an agent-shortened binary as a truncation marker", %{conn: conn} do
      stub_info()
      marker = {:"$voyager_truncated", :binary, "abc", 9_000}
      stub_select(ok_chunk([{:key, marker}], :undefined, true))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-0-toggle", "abc…")
      assert has_element?(view, "#ets-records-0-truncated")
      refute has_element?(view, "#ets-records-1-truncated")

      view |> element("#ets-records-0-toggle") |> render_click()
      assert render(view) =~ "9 KB total"
    end
  end

  describe "lookup sidebar" do
    test "opens with the record's key and shows the looked-up record", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn
        _node, :ets_select_chunk, _args, _timeout ->
          ok_chunk([{:a, 1}])

        _node, :ets_lookup, args, timeout ->
          send(test, {:lookup, args, timeout})
          ok_chunk([{:a, 1}])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      refute has_element?(view, "#ets-lookup-sidebar")
      view |> element("#ets-records-0-lookup") |> render_click()
      render_async(view)

      assert_received {:lookup, [_table, :a, @budget], 5_000}
      assert has_element?(view, "#ets-lookup-sidebar")
      assert has_element?(view, "#ets-sidebar-key", ":a")
      assert has_element?(view, "#ets-lookup-0-term")
      assert has_element?(view, "#ets-lookup-record-0-copy")
      assert has_element?(view, "#ets-lookup-record-0-copy-source", "{:a, 1}")

      view |> element("#ets-sidebar-close") |> render_click()
      refute has_element?(view, "#ets-lookup-sidebar")
    end

    test "refetch re-runs the lookup with the sidebar's own settings", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn
        _node, :ets_select_chunk, _args, _timeout ->
          ok_chunk([{:a, 1}])

        _node, :ets_lookup, args, timeout ->
          send(test, {:lookup, args, timeout})
          ok_chunk([{:a, 1}])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      view |> element("#ets-records-0-lookup") |> render_click()
      render_async(view)
      assert_received {:lookup, [_table, :a, @budget], 5_000}

      view
      |> element("#ets-lookup-controls")
      |> render_change(%{"lookup" => %{"budget" => "200", "timeout" => "2000"}})

      view |> element("#ets-lookup-refetch") |> render_click()
      render_async(view)

      assert_received {:lookup, [_table, :a, 200], 2_000}
    end

    test "reports a key that no longer matches a record", %{conn: conn} do
      stub_info()

      stub_agent(fn
        _node, :ets_select_chunk, _args, _timeout -> ok_chunk([{:a, 1}])
        _node, :ets_lookup, _args, _timeout -> ok_chunk([])
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      view |> element("#ets-records-0-lookup") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-lookup-empty")
    end

    test "offers no lookup for a bag table", %{conn: conn} do
      stub_select(ok_chunk([{:a, 1}]), type: :bag)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-0-toggle")
      refute has_element?(view, "#ets-records-0-lookup")
    end

    test "disables the lookup when the key is not a lookupable type", %{conn: conn} do
      stub_info()
      stub_select(ok_chunk([{{:composite, 1}, :value}, {:plain, 2}]))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-0-lookup[disabled]")
      refute has_element?(view, "#ets-records-1-lookup[disabled]")
      assert has_element?(view, "#ets-records-1-lookup")
    end
  end

  describe "errors" do
    test "a badarg on the target maps to cannot read", %{conn: conn} do
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, _args, _timeout ->
        :erlang.error({:exception, :badarg, []})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-peek-error", "cannot be read")
    end

    test "a worker heap kill suggests a smaller page", %{conn: conn} do
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, _args, _timeout ->
        :erlang.error({:exception, :killed, []})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-peek-error", "smaller page size")
    end

    test "an empty table reports it rather than showing an empty list", %{conn: conn} do
      stub_info()
      stub_select(ok_chunk([]))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-empty")
    end
  end

  defp ok_chunk(records, continuation \\ :undefined, truncated \\ false) do
    {:ok, %{records: records, continuation: continuation, truncated: truncated}}
  end

  defp stub_info(opts \\ []) do
    stub_erpc(fn
      _node, :erlang, :list_to_existing_atom, _args, _timeout ->
        String.to_atom(@table)

      _node, :ets, :info, _args, _timeout ->
        table_info(opts)

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
    end)
  end

  defp stub_select(result, info_opts \\ []) do
    stub_agent(fn _node, :ets_select_chunk, _args, _timeout -> result end, info_opts)
  end

  # Layers the agent call onto the metadata stub, so both reads answer from one
  # `Voyager.ErpcMock` stub.
  defp stub_agent(fun, info_opts \\ []) do
    stub(Voyager.ErpcMock, :call, fn
      node, :voyager_agent, agent_fun, args, timeout ->
        fun.(node, agent_fun, args, timeout)

      _node, :erlang, :list_to_existing_atom, _args, _timeout ->
        String.to_atom(@table)

      _node, :ets, :info, _args, _timeout ->
        table_info(info_opts)

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
    end)
  end

  defp stub_erpc(fun), do: stub(Voyager.ErpcMock, :call, fun)

  defp ref_path(ref) do
    "/node/#{@node_name}/ets-tables/#{URI.encode_www_form(inspect(ref))}"
  end

  defp table_info(opts) do
    [
      name: String.to_atom(@table),
      named_table: true,
      protection: Keyword.get(opts, :protection, :public),
      type: Keyword.get(opts, :type, :set),
      size: 3,
      memory: 100,
      owner: self(),
      heir: :none,
      keypos: 1,
      compressed: false,
      read_concurrency: false,
      write_concurrency: false
    ]
  end
end
