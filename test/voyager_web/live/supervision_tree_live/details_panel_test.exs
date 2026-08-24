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

    test "caps the expanded link list", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      sup_key: sup_key
    } do
      # 206 links (linked port + 205 pids): expanding renders the first 200 and
      # reports the rest as overflow rather than emitting a chip per link.
      link_pids = for n <- 1..205, do: :erlang.list_to_pid(~c"<0.#{200 + n}.0>")
      last_link = link_pids |> List.last() |> pid_key()

      # Same 9 calls as "renders process details for a supervisor".
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      view |> element("#details-panel-toggle-links") |> render_click()

      assert has_element?(view, "#details-panel-toggle-links", "Show Less")
      assert has_element?(view, "#details-panel", "+6 more")
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

    test "clicking a linked port that exists in the tree selects that node", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key,
      port_key: port_key
    } do
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      assert has_element?(view, "#details-panel", "Supervisor")

      view |> element("#details-panel-link-0") |> render_click()
      flush(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel", "Port")
      assert has_element?(view, "#details-panel", port_key)
      assert has_element?(view, "#details-panel-back")

      assert has_element?(
               view,
               "#details-panel",
               "This is not a process node, so no process information is available."
             )

      expect_process_info_fetch(sup_pid, [port | link_pids])

      view |> element("#details-panel-back") |> render_click()
      render_async(view)

      assert has_element?(view, "#details-panel", "Supervisor")
      assert has_element?(view, "#details-panel", "demo_supervisor")
      refute has_element?(view, "#details-panel-back")
    end

    test "clicking a linked pid not in the tree still opens it as the selected node", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key
    } do
      expect_supervision_erpc(9, sup_pid, [port], link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      render_async(view)

      target = hd(link_pids)
      target_key = pid_key(target)

      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [^target, keys], _timeout
                                         when is_list(keys) ->
        process_info_kw(keys, [], registered_name: :linked_worker)
      end)

      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:wordsize], _timeout ->
        8
      end)

      # Index 1: index 0 is the supervisor's linked port, which is already in the tree.
      view |> element("#details-panel-link-1") |> render_click()
      flush(view)
      render_async(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel", "Process")
      assert has_element?(view, "#details-panel", "Not in tree")
      assert has_element?(view, "#details-panel-pid", target_key)
      assert has_element?(view, "#details-panel", "linked_worker")
      assert has_element?(view, "#details-panel-back")

      expect_process_info_fetch(sup_pid, [port | link_pids])

      view |> element("#details-panel-back") |> render_click()
      render_async(view)

      assert has_element?(view, "#details-panel", "Supervisor")
      assert has_element?(view, "#details-panel", "demo_supervisor")
      refute has_element?(view, "#details-panel-back")
    end

    test "clicking a linked app-master pid selects the app node", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port
    } do
      master_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> Process.exit(master_pid, :kill) end)

      # Distinct master vs root supervisor: the app wrapper is keyed
      # `app:demo_app` while PID-links look up the master's `<X.Y.Z>`.
      expect_supervision_erpc(9, sup_pid, [port], [master_pid], master_pid)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => pid_key(sup_pid)})
      render_async(view)

      expect_process_info_fetch(master_pid, [port, master_pid])

      # Index 0 is the linked port; index 1 is the application master.
      view |> element("#details-panel-link-1") |> render_click()
      flush(view)
      render_async(view)

      assert has_element?(view, "#details-panel", "App")
      refute has_element?(view, "#details-panel", "Not in tree")
      refute has_element?(view, "#details-panel", "Process")
    end

    test "clicking a linked pid hidden by max depth expands one stub level", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port
    } do
      mid_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      worker_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        Process.exit(mid_pid, :kill)
        Process.exit(worker_pid, :kill)
      end)

      ctx = %{sup: sup_pid, mid: mid_pid, worker: worker_pid, port: port}

      stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
        depth_limited_reply(mod, fun, args, ctx)
      end)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => pid_key(mid_pid)})
      render_async(view)

      assert has_element?(view, "#details-panel", "Supervisor")
      refute has_element?(view, "#details-panel", "Not in tree")

      view |> element("#details-panel-link-0") |> render_click()
      flush(view)
      await_tree_ok(view)
      render_async(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert has_element?(view, "#details-panel", "Worker")
      assert has_element?(view, "#details-panel", "hidden_worker")
      assert has_element?(view, "#details-panel-pid", pid_key(worker_pid))
      assert has_element?(view, "#details-panel-back")
      refute has_element?(view, "#details-panel", "Not in tree")
      refute has_element?(view, "#details-panel", "Process")
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

  defp expect_supervision_erpc(times, sup_pid, linked_ports, link_pids, master_pid \\ nil) do
    master = master_pid || sup_pid

    expect(Voyager.ErpcMock, :call, times, fn _node, mod, fun, args, _timeout ->
      supervision_reply(mod, fun, args, sup_pid, linked_ports, link_pids, master)
    end)
  end

  defp expect_process_info_fetch(pid, links) do
    expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [^pid, keys], _timeout
                                       when is_list(keys) ->
      process_info_kw(keys, links)
    end)

    expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:wordsize], _timeout ->
      8
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

  # `select-link` notifies the parent LiveView via send/2; drain that message
  # before asserting on the updated selection.
  defp flush(view), do: _ = :sys.get_state(view.pid)

  defp pid_key(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp supervision_reply(mod, fun, args, sup, linked, links) do
    supervision_reply(mod, fun, args, sup, linked, links, sup)
  end

  defp supervision_reply(:application, :which_applications, [], _sup, _linked, _links, _master),
    do: @apps

  defp supervision_reply(:lists, :map, [fun, list], sup_pid, _linked, _links, master_pid) do
    case mfa(fun) do
      {:application_controller, :get_master, 1} ->
        Enum.map(list, fn _app -> master_pid end)

      {:application_master, :get_child, 1} ->
        Enum.map(list, fn _master -> {sup_pid, :demo_app} end)

      {:supervisor, :which_children, 1} ->
        Enum.map(list, fn _sup -> [] end)

      {:supervisor, :count_children, 1} ->
        Enum.map(list, fn _sup -> [specs: 0, active: 0, supervisors: 0, workers: 0] end)
    end
  end

  defp supervision_reply(
         :lists,
         :zipwith,
         [_fun, pids, dup_keys],
         _sup,
         linked_ports,
         _links,
         _master
       ) do
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

  defp supervision_reply(:erlang, :system_info, [:wordsize], _sup, _linked, _links, _master),
    do: 8

  defp supervision_reply(:erlang, :process_info, [_pid, keys], _sup, linked, link_pids, _master)
       when is_list(keys) do
    process_info_kw(keys, linked ++ link_pids)
  end

  # Root is expanded at default depth 3; `mid` is a stub (`count_children` only)
  # until a PID-link click adds it to `expanded_pids`.
  defp depth_limited_reply(:application, :which_applications, [], _ctx), do: @apps

  defp depth_limited_reply(:lists, :map, [fun, list], ctx) do
    case mfa(fun) do
      {:application_controller, :get_master, 1} ->
        Enum.map(list, fn _app -> ctx.sup end)

      {:application_master, :get_child, 1} ->
        Enum.map(list, fn _master -> {ctx.sup, :demo_app} end)

      {:supervisor, :which_children, 1} ->
        Enum.map(list, &which_children_for(&1, ctx))

      {:supervisor, :count_children, 1} ->
        Enum.map(list, &count_children_for(&1, ctx))
    end
  end

  defp depth_limited_reply(:supervisor, :which_children, [pid], ctx),
    do: which_children_for(pid, ctx)

  defp depth_limited_reply(:supervisor, :count_children, [pid], ctx),
    do: count_children_for(pid, ctx)

  defp depth_limited_reply(:lists, :zipwith, [_fun, pids, dup_keys], ctx) do
    keys = List.first(dup_keys) || []

    Enum.map(pids, fn pid ->
      cond do
        keys == [:dictionary] ->
          [dictionary: []]

        Enum.sort(keys) == Enum.sort(@process_info_keys) ->
          [
            registered_name: if(pid == ctx.worker, do: :hidden_worker, else: :mid_supervisor),
            initial_call: {:supervisor, :init, 1},
            current_function: {:gen_server, :loop, 7},
            links: [ctx.port],
            monitors: [],
            monitored_by: []
          ]

        true ->
          :undefined
      end
    end)
  end

  defp depth_limited_reply(:erlang, :system_info, [:wordsize], _ctx), do: 8

  defp depth_limited_reply(:erlang, :process_info, [pid, keys], ctx) when is_list(keys) do
    cond do
      pid == ctx.mid ->
        process_info_kw(keys, [ctx.worker], registered_name: :mid_supervisor)

      pid == ctx.worker ->
        process_info_kw(keys, [], registered_name: :hidden_worker)

      true ->
        process_info_kw(keys, [])
    end
  end

  defp which_children_for(pid, %{sup: pid, mid: mid}),
    do: [{:mid_supervisor, mid, :supervisor, []}]

  defp which_children_for(pid, %{mid: pid, worker: worker}),
    do: [{:hidden_worker, worker, :worker, []}]

  defp which_children_for(_pid, _ctx), do: []

  defp count_children_for(pid, %{mid: pid}),
    do: [specs: 1, active: 1, supervisors: 0, workers: 1]

  defp count_children_for(pid, %{sup: pid}),
    do: [specs: 1, active: 1, supervisors: 1, workers: 0]

  defp count_children_for(_pid, _ctx),
    do: [specs: 0, active: 0, supervisors: 0, workers: 0]

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
