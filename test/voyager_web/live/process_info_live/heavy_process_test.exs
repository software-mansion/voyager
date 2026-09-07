defmodule VoyagerWeb.ProcessInfoLive.HeavyProcessTest do
  # async: false because these tests swap the global erpc impl to the real
  # `Voyager.Erpc.Impl` and inspect live local processes through it.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Test.FixtureApp.Worker
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

  defp open!(conn, pid) do
    path = ~p"/node/#{@node_name}/processes/#{Formatters.format_pid(pid)}"
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    render_async(view, 5_000)
    view
  end

  test "a gen_server with a huge state serves calls throughout inspection", %{conn: conn} do
    worker = start_supervised!({Worker, 0})
    state = for n <- 1..50_000, do: {n, String.duplicate("payload", 10)}
    :ok = GenServer.call(worker, {:put_state, state})

    feeder =
      start_supervised!(
        {Task,
         fn ->
           for _ <- 1..50_000, do: GenServer.cast(worker, :noop)
         end}
      )

    feeder_ref = Process.monitor(feeder)

    view = open!(conn, worker)
    view |> element("#process-tab-state") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#panel-state-fetched-at")
    assert has_element?(view, "#process-state-root-truncated")

    assert_receive {:DOWN, ^feeder_ref, :process, _pid, :normal}, 10_000
    assert length(GenServer.call(worker, :get_state, 10_000)) == 50_000
  end

  test "a huge mailbox is read without consuming it", %{conn: conn} do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready
    on_exit(fn -> Process.exit(pid, :kill) end)

    for n <- 1..10_000, do: send(pid, {:job, n})

    view = open!(conn, pid)
    view |> element("#process-tab-messages") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#panel-messages h4", "(10,000 in queue)")
    assert has_element?(view, "#process-messages-truncated")
    assert Process.info(pid, :message_queue_len) == {:message_queue_len, 10_000}
  end

  test "a busy process keeps making progress while inspection times out", %{conn: conn} do
    counter = :counters.new(1, [])

    pid = spawn(fn -> burn(counter) end)
    ref = Process.monitor(pid)
    on_exit(fn -> Process.exit(pid, :kill) end)

    view = open!(conn, pid)

    view
    |> element("#panel-state-timeout-form")
    |> render_change(%{"section" => "state", "timeout" => "1000"})

    view |> element("#process-tab-state") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#process-state-error", "Timed out while fetching")
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert_progress(counter, :counters.get(counter, 1))
  end

  defp burn(counter) do
    :counters.add(counter, 1, 1)
    burn(counter)
  end

  defp assert_progress(counter, seen, tries \\ 1_000_000)
  defp assert_progress(_counter, _seen, 0), do: flunk("busy process stopped making progress")

  defp assert_progress(counter, seen, tries) do
    if :counters.get(counter, 1) > seen do
      :ok
    else
      :erlang.yield()
      assert_progress(counter, seen, tries - 1)
    end
  end
end
