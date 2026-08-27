defmodule VoyagerWeb.SupervisionTreeLive.DetailsPanelTest do
  # async: false because we use Mox global mode (the supervision-tree walk and
  # ProcessInfo.fetch run in tasks under the shared TaskSupervisor).
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @path "/node/demo@localhost/supervision-tree"

  @apps [
    {:demo_app, ~c"Demo app", ~c"1.0.0"}
  ]

  @process_info_keys [
    :registered_name,
    :initial_call,
    :current_function,
    :links,
    :monitors,
    :monitored_by
  ]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))

    sup_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    port = Port.open({:spawn, "cat"}, [:binary])

    link_pids = for n <- 1..20, do: :erlang.list_to_pid(~c"<0.#{200 + n}.0>")

    on_exit(fn ->
      Process.exit(sup_pid, :kill)

      if Port.info(port) do
        Port.close(port)
      end
    end)

    %{
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: pid_key(sup_pid),
      port_key: inspect(port),
      twentieth_link: link_pids |> Enum.at(19) |> pid_key()
    }
  end

  describe "DetailsPanel" do
    test "renders process details for a supervisor", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key
    } do
      # 9 erpc calls: which_applications + app masters (mount), then masters +
      # root children + root ancestors + which_children batch + process_info
      # hydrate (walk), then process_info + wordsize (ProcessInfo.fetch)
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      # Assertions are scoped to #details-panel: words like "Supervisor" also
      # appear in the graph legend, so bare `html =~` checks would be vacuous.
      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel-refresh")
      assert has_element?(view, "#details-panel", "Supervisor")
      assert has_element?(view, "#details-panel", "demo_supervisor")
      assert has_element?(view, "#details-panel", "Overview")
      assert has_element?(view, "#details-panel", "Binary")
      assert has_element?(view, "#details-panel", "Last calls")
      assert has_element?(view, "#details-panel", "Trace")
      assert has_element?(view, "#details-panel", "Suspending")
      assert has_element?(view, "#details-panel", "Sequential trace token")
      assert has_element?(view, "#details-panel", "Error handler")
      assert has_element?(view, "#details-panel", ":error_handler")
      assert has_element?(view, "#details-panel", "Links")
      assert has_element?(view, "#details-panel", "Memory and Garbage Collection")
      refute has_element?(view, "#details-panel", "This is not a process node")
    end

    test "shows the non-process message for a port", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      port_key: port_key
    } do
      # Same 9 calls as the supervisor test minus ProcessInfo.fetch's
      # process_info + wordsize: port nodes have no pid to inspect.
      expect_supervision_erpc(7, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => port_key})
      render(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel", "Port")

      assert has_element?(
               view,
               "#details-panel",
               "This is not a process node, so no process information is available."
             )

      refute has_element?(view, "#details-panel", "Overview")
    end

    test "Show More and Show Less toggle truncated links", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key,
      twentieth_link: twentieth_link
    } do
      # Same 9 calls as "renders process details for a supervisor".
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      assert has_element?(view, "#details-panel-toggle-links", "Show More")
      refute has_element?(view, "#details-panel", twentieth_link)

      view |> element("#details-panel-toggle-links") |> render_click()

      assert has_element?(view, "#details-panel-toggle-links", "Show Less")
      assert has_element?(view, "#details-panel", twentieth_link)

      view |> element("#details-panel-toggle-links") |> render_click()

      assert has_element?(view, "#details-panel-toggle-links", "Show More")
      refute has_element?(view, "#details-panel", twentieth_link)
    end

    test "collapses expanded links when another node is selected", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key,
      port_key: port_key,
      twentieth_link: twentieth_link
    } do
      # The 9 calls of the initial open plus the process_info/system_info pair
      # of re-selecting the supervisor.
      expect_supervision_erpc(11, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      view |> element("#details-panel-toggle-links") |> render_click()

      assert has_element?(view, "#details-panel-toggle-links", "Show Less")
      assert has_element?(view, "#details-panel", twentieth_link)

      # The port carries no process info, so only the selection changes.
      render_hook(view, "select-node", %{"key" => port_key})
      render(view)

      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      assert has_element?(view, "#details-panel-toggle-links", "Show More")
      refute has_element?(view, "#details-panel", twentieth_link)
    end

    test "caps the expanded link list", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      sup_key: sup_key
    } do
      # 205 links: expanding renders the first 200 and reports the rest as
      # overflow rather than emitting a chip per link.
      link_pids = for n <- 1..205, do: :erlang.list_to_pid(~c"<0.#{200 + n}.0>")
      last_link = link_pids |> List.last() |> pid_key()

      # Same 9 calls as "renders process details for a supervisor".
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      view |> element("#details-panel-toggle-links") |> render_click()

      assert has_element?(view, "#details-panel-toggle-links", "Show Less")
      assert has_element?(view, "#details-panel", "+5 more")
      refute has_element?(view, "#details-panel", last_link)
    end

    test "refresh button re-fetches process information", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key
    } do
      # Open the panel with the default ProcessInfo payload (reductions 1,234).
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      assert has_element?(view, "#details-panel-refresh")
      assert has_element?(view, "#details-panel", "1,234")
      assert has_element?(view, "#details-panel", "waiting")
      refute has_element?(view, "#details-panel", "9,999")
      refute has_element?(view, "#details-panel", "running")
      refute has_element?(view, "#details-panel", "Failed to load node details.")

      # Refresh: ProcessInfo.fetch calls process_info then system_info — return
      # a different snapshot so the panel content visibly changes.
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [_pid, keys], _timeout
                                         when is_list(keys) ->
        process_info_kw(keys, link_pids,
          status: :running,
          reductions: 9_999
        )
      end)

      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
      end)

      view |> element("#details-panel-refresh") |> render_click()
      render_async(view)

      assert has_element?(view, "#details-panel", "9,999")
      assert has_element?(view, "#details-panel", "running")
      refute has_element?(view, "#details-panel", "1,234")
      refute has_element?(view, "#details-panel", "waiting")
      refute has_element?(view, "#details-panel", "Failed to load node details.")
    end

    test "refresh button is rate limited", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key
    } do
      previous = Application.get_env(:voyager, :process_info_min_refresh_ms)
      Application.put_env(:voyager, :process_info_min_refresh_ms, 1_000)
      on_exit(fn -> Application.put_env(:voyager, :process_info_min_refresh_ms, previous) end)

      # Exactly the calls the initial open needs: a second fetch would blow the
      # expectation and surface as a failed panel.
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      view |> element("#details-panel-refresh") |> render_click()
      render_async(view)

      assert has_element?(view, "#details-panel", "1,234")
      refute has_element?(view, "#details-panel", "Failed to load node details.")
    end

    test "refresh button is hidden for non-process nodes", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      port_key: port_key
    } do
      expect_supervision_erpc(7, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => port_key})
      render(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      refute has_element?(view, "#details-panel-refresh")
    end

    test "closes the details panel when the selected node disappears on refresh", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      port_key: port_key
    } do
      # Toggle whether the supervisor still links the port between fetches. The
      # port only appears in the tree via that link, so dropping it on refresh
      # removes the selected key and must close the panel.
      {:ok, linked} = Agent.start_link(fn -> [port] end)

      on_exit(fn ->
        try do
          Agent.stop(linked)
        catch
          :exit, _ -> :ok
        end
      end)

      stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
        supervision_reply(mod, fun, args, sup_pid, Agent.get(linked, & &1), link_pids)
      end)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => port_key})
      render(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel", "Port")

      Agent.update(linked, fn _ -> [] end)

      view |> element("#refresh-interval-refresh-now-button") |> render_click()
      await_tree_ok(view)

      assert has_element?(view, "#details-panel.translate-x-full")
      refute has_element?(view, "#details-panel.translate-x-0")
    end
  end

  defp expect_supervision_erpc(times, sup_pid, linked_ports, link_pids) do
    expect(Voyager.ErpcMock, :call, times, fn _node, mod, fun, args, _timeout ->
      supervision_reply(mod, fun, args, sup_pid, linked_ports, link_pids)
    end)
  end

  defp open_tree!(conn) do
    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#refresh-interval-form", %{"interval" => "off"})
    |> render_change()

    view
    |> form("#supervision-tree-controls", %{"tree_controls" => %{"apps" => ["demo_app"]}})
    |> render_change()

    await_tree_ok(view)
    view
  end

  # Polls until the tree fetch lands. The fetch completes via a raw
  # `{ref, result}` message from Task.Supervisor.async_nolink to the LiveView,
  # so `render_async/1` cannot await it — polling is the only synchronization
  # available here (worst case 50 × 20ms = 1s).
  defp await_tree_ok(view, attempts \\ 50)

  defp await_tree_ok(_view, 0), do: flunk("timed out waiting for supervision tree status ok")

  defp await_tree_ok(view, attempts) do
    if has_element?(view, "#supervision-tree-status", "ok") do
      :ok
    else
      receive do
      after
        20 -> :ok
      end

      _ = render(view)
      await_tree_ok(view, attempts - 1)
    end
  end

  defp pid_key(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp supervision_reply(:application, :which_applications, [], _sup, _linked, _links), do: @apps

  defp supervision_reply(:lists, :map, [fun, list], sup_pid, _linked, _links) do
    case mfa(fun) do
      {:application_controller, :get_master, 1} ->
        Enum.map(list, fn _app -> sup_pid end)

      {:application_master, :get_child, 1} ->
        Enum.map(list, fn _master -> {sup_pid, :demo_app} end)

      {:supervisor, :which_children, 1} ->
        Enum.map(list, fn _sup -> [] end)

      {:supervisor, :count_children, 1} ->
        Enum.map(list, fn _sup -> [specs: 0, active: 0, supervisors: 0, workers: 0] end)
    end
  end

  defp supervision_reply(:lists, :zipwith, [_fun, pids, dup_keys], _sup, linked_ports, _links) do
    keys = List.first(dup_keys) || []

    Enum.map(pids, fn _pid ->
      cond do
        keys == [:dictionary] ->
          [dictionary: []]

        Enum.sort(keys) == Enum.sort(@process_info_keys) ->
          [
            registered_name: :demo_supervisor,
            initial_call: {:supervisor, :init, 1},
            current_function: {:gen_server, :loop, 7},
            links: linked_ports,
            monitors: [],
            monitored_by: []
          ]

        true ->
          :undefined
      end
    end)
  end

  defp supervision_reply(:erlang, :system_info, [:wordsize], _sup, _linked, _links), do: 8

  defp supervision_reply(:erlang, :process_info, [_pid, keys], _sup, _linked, link_pids)
       when is_list(keys) do
    process_info_kw(keys, link_pids)
  end

  defp process_info_kw(keys, link_pids, overrides \\ []) do
    info =
      Map.merge(
        %{
          initial_call: {:supervisor, :init, 1},
          current_function: {:gen_server, :loop, 7},
          registered_name: :demo_supervisor,
          status: :waiting,
          message_queue_len: 0,
          group_leader: self(),
          priority: :normal,
          trap_exit: true,
          reductions: 1_234,
          binary: [],
          last_calls: false,
          catchlevel: 0,
          trace: 0,
          suspending: [],
          sequential_trace_token: [],
          error_handler: :error_handler,
          links: link_pids,
          memory: 2_048,
          total_heap_size: 233,
          heap_size: 100,
          stack_size: 12,
          garbage_collection: [min_heap_size: 233, fullsweep_after: 65_535]
        },
        Map.new(overrides)
      )

    Enum.map(keys, fn key -> {key, Map.fetch!(info, key)} end)
  end

  defp mfa(fun) do
    info = :erlang.fun_info(fun)
    {info[:module], info[:name], info[:arity]}
  end
end
