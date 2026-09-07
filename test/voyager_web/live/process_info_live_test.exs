defmodule VoyagerWeb.ProcessInfoLiveTest do
  # async: false because these tests swap the global erpc impl to the real
  # `Voyager.Erpc.Impl` and inspect live local processes through it.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Test.FixtureApp.Worker
  alias Voyager.Test.RemoteFixture
  alias VoyagerWeb.Formatters

  @node_name "nonode@nohost"

  setup_all do
    path = :voyager |> :code.priv_dir() |> Path.join("voyager_agent.erl")
    {:ok, module, binary} = :compile.file(String.to_charlist(path), [:binary])
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    :ok
  end

  setup do
    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

  defp open!(conn, pid_string) do
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/processes/#{pid_string}")
    render_async(view, 2_000)
    render_async(view, 2_000)
    view
  end

  defp open_tab!(view, tab, timeout \\ 2_000) do
    view |> element("#process-tab-#{tab}") |> render_click()
    render_async(view, timeout)
    view
  end

  defp spawn_idle(setup_fun \\ fn -> :ok end) do
    parent = self()

    pid =
      spawn(fn ->
        setup_fun.()
        send(parent, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "supervisor" do
    setup do
      fixture_app = RemoteFixture.start_fixture_app!()
      on_exit(fn -> Application.stop(fixture_app) end)
      %{sup: Process.whereis(Voyager.Test.FixtureApp.RootSupervisor)}
    end

    test "loads overview and relations on mount", %{conn: conn, sup: sup} do
      view = open!(conn, Formatters.format_pid(sup))

      assert has_element?(view, "#process-info-pid", Formatters.format_pid(sup))
      assert has_element?(view, "#panel-overview", "Voyager.Test.FixtureApp.RootSupervisor")
      assert has_element?(view, "#panel-overview", ":gen_server.loop/5")
      assert has_element?(view, "#panel-overview", "Heap size")

      {:links, links} = Process.info(sup, :links)

      for linked <- links, is_pid(linked) do
        assert has_element?(view, "#process-links", Formatters.format_pid(linked))
      end

      assert has_element?(view, "#process-links a")
      assert has_element?(view, "#panel-overview a[href*='processes']")
    end

    test "shows the supervisor state after opening the State tab", %{conn: conn, sup: sup} do
      view = conn |> open!(Formatters.format_pid(sup)) |> open_tab!(:state)

      assert has_element?(view, "#process-state", ":state")
    end
  end

  describe "gen_server" do
    test "shows its state after opening the State tab", %{conn: conn} do
      worker = start_supervised!({Worker, 41})

      view = conn |> open!(Formatters.format_pid(worker)) |> open_tab!(:state)

      assert has_element?(view, "#panel-state-fetched-at", "ms")
      assert has_element?(view, "#process-state", "41")
    end
  end

  describe "plain process" do
    test "lists queued messages without consuming them", %{conn: conn} do
      pid = spawn_idle()
      for n <- 1..3, do: send(pid, {:job, n})

      view = conn |> open!(Formatters.format_pid(pid)) |> open_tab!(:messages)

      assert has_element?(view, "#panel-messages h4", "(3 in queue)")
      assert has_element?(view, "#message-0", "job")
      assert has_element?(view, "#message-2")
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 3}
    end

    test "honours the messages limit control", %{conn: conn} do
      pid = spawn_idle()
      for n <- 1..3, do: send(pid, {:job, n})

      view = open!(conn, Formatters.format_pid(pid))

      view
      |> element("#panel-messages-limit-form")
      |> render_change(%{"section" => "messages", "limit" => "2"})

      open_tab!(view, :messages)

      assert has_element?(view, "#panel-messages h4", "(3 in queue)")
      assert has_element?(view, "#message-1")
      refute has_element?(view, "#message-2")
      assert has_element?(view, "#process-messages-truncated")
    end

    test "renders dictionary keys and values as term inspectors", %{conn: conn} do
      pid = spawn_idle(fn -> Process.put({:shard, 7}, %{status: :ok}) end)

      view = conn |> open!(Formatters.format_pid(pid)) |> open_tab!(:dictionary)

      assert has_element?(view, "#dict-key-0", "shard")
      assert has_element?(view, "#dict-entry-0", "status")
    end

    test "reports a state timeout without killing the process", %{conn: conn} do
      pid = spawn_idle()
      ref = Process.monitor(pid)
      view = open!(conn, Formatters.format_pid(pid))

      view
      |> element("#panel-state-timeout-form")
      |> render_change(%{"section" => "state", "timeout" => "1000"})

      open_tab!(view, :state, 5_000)

      assert has_element?(view, "#process-state-error", "Timed out while fetching")
      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  describe "dead process" do
    test "shows an error for a process that is gone", %{conn: conn} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      view = open!(conn, Formatters.format_pid(pid))

      assert has_element?(view, "#panel-overview .alert-error")
    end
  end

  describe "sidebar mode" do
    test "navigation links carry the sidebar query param", %{conn: conn} do
      pid = spawn_idle()
      path = ~p"/node/#{@node_name}/processes/#{Formatters.format_pid(pid)}"

      {:ok, view, _html} = live(conn, path <> "?sidebar=compact")
      render_async(view, 2_000)

      assert has_element?(view, "#back-to-processes[href*='sidebar=compact']")
    end
  end

  describe "invalid pid" do
    test "fails both mount fetches for a malformed pid string", %{conn: conn} do
      view = open!(conn, "not-a-pid")

      assert has_element?(view, "#panel-overview .alert-error")
      assert has_element?(view, "#process-relations-error", "Invalid PID")
    end
  end
end
