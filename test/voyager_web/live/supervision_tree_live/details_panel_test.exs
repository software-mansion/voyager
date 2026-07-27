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
    :links,
    :monitors,
    :monitored_by
  ]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))

    sup_pid = spawn(fn -> Process.sleep(:infinity) end)
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
      # mount + app list + tree walk + ProcessInfo.fetch (process_info + wordsize)
      expect_supervision_erpc(9, sup_pid, port, link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => sup_key})
      html = render_async(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert html =~ "Supervisor"
      assert html =~ "demo_supervisor"
      assert html =~ "Overview"
      assert html =~ "Links"
      assert html =~ "Memory and Garbage Collection"
      refute html =~ "This is not a process node"
    end

    test "shows the non-process message for a port", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      port_key: port_key
    } do
      # mount + app list + tree walk (port nodes skip ProcessInfo.fetch)
      expect_supervision_erpc(7, sup_pid, port, link_pids)

      view = open_tree!(conn)
      render_hook(view, "select-node", %{"key" => port_key})
      html = render(view)

      assert has_element?(view, "#details-panel.translate-x-0")
      assert html =~ "Port"
      assert html =~ "This is not a process node, so no process information is available."
      refute html =~ "Overview"
    end

    test "Show More and Show Less toggle truncated links", %{
      conn: conn,
      sup_pid: sup_pid,
      port: port,
      link_pids: link_pids,
      sup_key: sup_key,
      twentieth_link: twentieth_link
    } do
      expect_supervision_erpc(9, sup_pid, port, link_pids)

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
  end

  defp expect_supervision_erpc(times, sup_pid, port, link_pids) do
    expect(Voyager.ErpcMock, :call, times, fn _node, mod, fun, args, _timeout ->
      supervision_reply(mod, fun, args, sup_pid, port, link_pids)
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

  defp supervision_reply(:application, :which_applications, [], _sup, _port, _links), do: @apps

  defp supervision_reply(:lists, :map, [fun, list], sup_pid, _port, _links) do
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

  defp supervision_reply(:lists, :zipwith, [_fun, pids, dup_keys], _sup, port, _links) do
    keys = List.first(dup_keys) || []

    Enum.map(pids, fn _pid ->
      cond do
        keys == [:dictionary] ->
          [dictionary: []]

        Enum.sort(keys) == Enum.sort(@process_info_keys) ->
          [
            registered_name: :demo_supervisor,
            links: [port],
            monitors: [],
            monitored_by: []
          ]

        true ->
          :undefined
      end
    end)
  end

  defp supervision_reply(:erlang, :system_info, [:wordsize], _sup, _port, _links), do: 8

  defp supervision_reply(:erlang, :process_info, [_pid, keys], _sup, _port, link_pids)
       when is_list(keys) do
    info = %{
      initial_call: {:supervisor, :init, 1},
      current_function: {:gen_server, :loop, 7},
      registered_name: :demo_supervisor,
      status: :waiting,
      message_queue_len: 0,
      group_leader: self(),
      priority: :normal,
      trap_exit: true,
      reductions: 1_234,
      catchlevel: 0,
      links: link_pids,
      memory: 2_048,
      total_heap_size: 233,
      heap_size: 100,
      stack_size: 12,
      garbage_collection: [min_heap_size: 233, fullsweep_after: 65_535]
    }

    Enum.map(keys, fn key -> {key, Map.fetch!(info, key)} end)
  end

  defp mfa(fun) do
    info = :erlang.fun_info(fun)
    {info[:module], info[:name], info[:arity]}
  end
end
