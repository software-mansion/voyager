defmodule VoyagerWeb.ProcessDetailsLiveTest do
  # async: false because we use Mox global mode: ProcessInfo.fetch runs in an
  # async task, so erpc expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes
  alias Voyager.Queries.Processes

  @node_name "demo@localhost"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))

    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    %{pid: pid, path: path(pid)}
  end

  defp path(pid), do: "/node/#{@node_name}/processes/#{Processes.format_pid(pid)}"

  # `ProcessInfo.fetch/2` makes two remote calls: process_info then wordsize.
  defp stub_process_info(overrides \\ []) do
    raw =
      Keyword.merge(
        [
          initial_call: {:proc_lib, :init_p, 5},
          current_function: {:gen_server, :loop, 7},
          registered_name: [],
          status: :waiting,
          message_queue_len: 3,
          group_leader: self(),
          priority: :normal,
          trap_exit: false,
          reductions: 4_242,
          binary: [],
          last_calls: false,
          catchlevel: 0,
          trace: 0,
          suspending: [],
          sequential_trace_token: [],
          error_handler: :error_handler,
          links: [],
          memory: 2_048,
          total_heap_size: 100,
          heap_size: 60,
          stack_size: 40,
          garbage_collection: [min_heap_size: 233, fullsweep_after: 65_535]
        ],
        overrides
      )

    stub(Voyager.ErpcMock, :call, fn
      _node, :erlang, :process_info, _args, _timeout -> raw
      _node, :erlang, :system_info, [:wordsize], _timeout -> 8
    end)
  end

  describe "rendering details" do
    test "renders the pid as the heading", %{conn: conn, pid: pid, path: path} do
      stub_process_info()

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      assert has_element?(view, "h1", Processes.format_pid(pid))
    end

    test "renders the overview and memory sections", %{conn: conn, path: path} do
      stub_process_info()

      {:ok, view, _html} = live(conn, path)
      html = render_async(view)

      assert html =~ "Initial call"
      assert html =~ "Reductions"
      assert html =~ "Memory and Garbage Collection"
    end

    test "formats process values for display", %{conn: conn, path: path} do
      stub_process_info()

      {:ok, view, _html} = live(conn, path)
      html = render_async(view)

      # reductions 4_242 thousands-separated, memory 2_048 bytes as KB.
      assert html =~ "4,242"
      assert html =~ "2 KB"
      assert html =~ ":proc_lib.init_p/5"
    end

    test "offers a link back to the process list", %{conn: conn, path: path} do
      stub_process_info()

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      href = "/node/#{URI.encode_www_form(@node_name)}/processes"

      assert has_element?(view, ~s|#back-to-processes[href="#{href}"]|)
    end

    test "refetches on manual refresh", %{conn: conn, path: path} do
      test = self()

      stub(Voyager.ErpcMock, :call, fn
        _node, :erlang, :process_info, _args, _timeout ->
          send(test, :fetched)
          :undefined

        _node, :erlang, :system_info, [:wordsize], _timeout ->
          8
      end)

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      assert_received :fetched

      view |> element("#refresh-process-info") |> render_click()
      render_async(view)

      assert_received :fetched
    end
  end

  describe "error states" do
    test "reports a dead process rather than showing another process's details", %{
      conn: conn,
      path: path
    } do
      stub(Voyager.ErpcMock, :call, fn
        _node, :erlang, :process_info, _args, _timeout -> :undefined
        _node, :erlang, :system_info, [:wordsize], _timeout -> 8
      end)

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      assert has_element?(view, "#process-details-error")
      assert render(view) =~ "no longer alive"
    end

    test "rejects a malformed pid without calling the remote", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/node/#{@node_name}/processes/not-a-pid")

      assert has_element?(view, "#process-details-error")
      assert render(view) =~ "not a valid process identifier"
    end

    test "reports an unreachable node", %{conn: conn, path: path} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      assert render(view) =~ "unreachable"
    end

    test "reports a timeout", %{conn: conn, path: path} do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :timeout})
      end)

      {:ok, view, _html} = live(conn, path)
      render_async(view)

      assert render(view) =~ "Timed out"
    end
  end
end
