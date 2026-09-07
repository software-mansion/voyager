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

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  describe "metadata" do
    test "renders the table name and its badges", %{conn: conn} do
      stub_info()

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#ets-table-name", @table)
      assert has_element?(view, "#ets-keypos-badge", "keypos 1")
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

    test "fetches a chunk on click and shows the truncation notice", %{conn: conn} do
      stub_info()
      stub_select({[{:a, 1}, {:b, 2}], :"$end_of_table"})

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records")
      assert has_element?(view, "#ets-truncation-notice")
      assert has_element?(view, "#ets-records-count", "2 records")
    end

    test "sends the selected chunk size and timeout to the agent", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, args, timeout ->
        send(test, {:called, args, timeout})
        :"$end_of_table"
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#ets-peek-controls")
      |> render_change(%{"peek" => %{"chunk_size" => "50", "timeout" => "2000"}})

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, [_table, 50, :undefined], 2_000}
    end

    test "keeps the previous chunk size when an edit is invalid", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, args, _timeout ->
        send(test, {:called, args})
        :"$end_of_table"
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> element("#ets-peek-controls")
      |> render_change(%{"peek" => %{"chunk_size" => "10", "timeout" => "999999"}})

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, [_table, 10, :undefined]}
    end
  end

  describe "paging" do
    test "passes the continuation back on load more and appends the records", %{conn: conn} do
      test = self()
      cont = {:ets_cont, 1}
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, _limit, continuation], _timeout ->
        send(test, {:called, continuation})

        case continuation do
          :undefined -> {[{:a, 1}], cont}
          ^cont -> {[{:b, 2}], :"$end_of_table"}
        end
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-count", "1 records")
      assert has_element?(view, "#ets-peek-more")

      view |> element("#ets-peek-more") |> render_click()
      render_async(view)

      assert_received {:called, :undefined}
      assert_received {:called, ^cont}
      assert has_element?(view, "#ets-records-count", "2 records")
      refute has_element?(view, "#ets-peek-more")
    end

    test "reload snapshot starts a new select rather than resuming", %{conn: conn} do
      test = self()
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, [_table, _limit, continuation], _timeout ->
        send(test, {:called, continuation})
        {[{:a, 1}], {:ets_cont, 1}}
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)
      assert_received {:called, :undefined}

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert_received {:called, :undefined}
      assert has_element?(view, "#ets-records-count", "1 records")
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

    test "a worker heap kill suggests a smaller chunk", %{conn: conn} do
      stub_info()

      stub_agent(fn _node, :ets_select_chunk, _args, _timeout ->
        :erlang.error({:exception, :killed, []})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-peek-error", "smaller chunk size")
    end

    test "an empty table reports it rather than showing an empty list", %{conn: conn} do
      stub_info()
      stub_select(:"$end_of_table")

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      assert has_element?(view, "#ets-records-empty")
    end
  end

  describe "truncated records" do
    test "renders an agent-shortened binary as a truncation marker", %{conn: conn} do
      stub_info()
      marker = {:"$voyager_truncated", :binary, "abc", 9_000}
      stub_select({[{:key, marker}], :"$end_of_table"})

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view |> element("#ets-peek-fetch") |> render_click()
      render_async(view)

      html = render(view)
      assert html =~ "9 KB total"
    end
  end

  defp stub_info(opts \\ []) do
    protection = Keyword.get(opts, :protection, :public)

    stub_erpc(fn
      _node, :erlang, :list_to_existing_atom, _args, _timeout ->
        String.to_atom(@table)

      _node, :ets, :info, _args, _timeout ->
        table_info(protection)

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
    end)
  end

  defp stub_select(result) do
    stub_agent(fn _node, :ets_select_chunk, _args, _timeout -> result end)
  end

  # Layers the agent call onto the metadata stub, so both reads answer from one
  # `Voyager.ErpcMock` stub.
  defp stub_agent(fun) do
    stub(Voyager.ErpcMock, :call, fn
      node, :voyager_agent, agent_fun, args, timeout ->
        fun.(node, agent_fun, args, timeout)

      _node, :erlang, :list_to_existing_atom, _args, _timeout ->
        String.to_atom(@table)

      _node, :ets, :info, _args, _timeout ->
        table_info(:public)

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
    end)
  end

  defp stub_erpc(fun), do: stub(Voyager.ErpcMock, :call, fun)

  defp table_info(protection) do
    [
      name: String.to_atom(@table),
      named_table: true,
      protection: protection,
      type: :set,
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
