defmodule Voyager.Services.ProcessInfoTest do
  # async: false because the real-node tests swap the global `:erpc` impl to
  # `Voyager.Erpc.Impl`. Running that concurrently with another async module
  # doing the same (node_info_test) makes whichever finishes first restore the
  # mock underneath the other, failing it with Mox.UnexpectedCallError.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Services.ProcessInfo

  setup :verify_on_exit!

  # The unbounded fetches call `:voyager_agent` on the remote. `.erl` sources
  # under priv/ are not built by mix, so compile and load the agent here to
  # exercise the real remote-side truncation against the local node.
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

  describe "fetch/2 against a live local process" do
    setup do
      Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
      on_exit(fn -> Application.put_env(:voyager, :erpc, Voyager.ErpcMock) end)
      :ok
    end

    test "returns fixed-size attributes and never leaks the raw dictionary or links" do
      pid = spawn_idle()
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:ok, info} = ProcessInfo.fetch(Node.self(), pid)

      assert info.status in [:waiting, :runnable, :running, :suspended, :garbage_collecting]
      assert is_integer(info.memory) and info.memory > 0
      assert is_integer(info.reductions)
      assert is_list(info.current_stacktrace)
      assert info.message_queue_data in [:on_heap, :off_heap]
      assert info.registered_name == nil
      assert info.label == nil
      assert info.parent == self()

      # The dictionary is never fetched, so nothing derived from it appears
      # here either -- callers use fetch_dictionary/3 instead.
      refute Map.has_key?(info, :dictionary)
      refute Map.has_key?(info, :ancestors)
      refute Map.has_key?(info, :links)
    end

    test "resolves registered_name for a registered process" do
      name = :"process_info_test_#{System.unique_integer([:positive])}"
      pid = spawn_idle()
      Process.register(pid, name)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:ok, info} = ProcessInfo.fetch(Node.self(), pid)
      assert info.registered_name == name
    end

    test "returns the raw initial_call, ignoring the $initial_call dictionary entry" do
      pid = spawn_idle(fn -> Process.put(:"$initial_call", {Voyager.Fixture, :init, 1}) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      {:initial_call, expected} = :erlang.process_info(pid, :initial_call)

      assert {:ok, info} = ProcessInfo.fetch(Node.self(), pid)

      # Reading $initial_call would mean copying the whole dictionary on the
      # eager path, so the raw value wins even though it is less informative.
      assert info.initial_call == expected
      refute info.initial_call == {Voyager.Fixture, :init, 1}
    end

    # `proc_lib:set_label/1` stores the label under `$process_label`, and the
    # `:label` key of `process_info/2` reads that single entry on the remote. So
    # the label survives dropping `:dictionary` from @keys: the VM does the
    # one-key lookup for us instead of us copying the whole dictionary back.
    test "resolves label from the native process label" do
      pid = spawn_idle(fn -> :proc_lib.set_label(:my_test_label) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:ok, info} = ProcessInfo.fetch(Node.self(), pid)
      assert info.label == :my_test_label
    end

    test "returns {:error, :dead} for a dead pid" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert {:error, :dead} == ProcessInfo.fetch(Node.self(), pid)
    end
  end

  describe "fetch/2 with non-pid input" do
    test "returns {:error, :not_a_pid} for a port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      assert {:error, :not_a_pid} == ProcessInfo.fetch(:demo@localhost, port)
    end

    test "returns {:error, :not_a_pid} for nil" do
      assert {:error, :not_a_pid} == ProcessInfo.fetch(:demo@localhost, nil)
    end
  end

  describe "fetch/2 error translation" do
    test "translates erpc timeout" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [_pid, keys], _timeout
                                         when is_list(keys) ->
        :erlang.error({:erpc, :timeout})
      end)

      assert {:error, :timeout} == ProcessInfo.fetch(:demo@localhost, self())
    end

    test "translates erpc noconnection" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [_pid, keys], _timeout
                                         when is_list(keys) ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} == ProcessInfo.fetch(:demo@localhost, self())
    end

    test "translates a raised remote exception" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :process_info, [_pid, keys], _timeout
                                         when is_list(keys) ->
        :erlang.error({:exception, :boom, []})
      end)

      assert {:error, {:remote_exception, :boom}} == ProcessInfo.fetch(:demo@localhost, self())
    end
  end

  describe "unbounded fetches against a live local process" do
    setup do
      Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
      on_exit(fn -> Application.put_env(:voyager, :erpc, Voyager.ErpcMock) end)
      :ok
    end

    test "fetch_links/3 returns a bounded payload including the linked process" do
      # Linked to a throwaway companion, not the test process itself: an
      # untrappable :kill on `pid` propagates the exit signal to whatever it
      # links, and the test process must not be on the receiving end of that.
      companion = spawn_idle()
      pid = spawn_idle(fn -> Process.link(companion) end)
      kill_on_exit([pid, companion])

      assert {:ok, %{total: total, truncated?: false, items: items}} =
               ProcessInfo.fetch_links(Node.self(), pid, 1_000)

      assert companion in items
      assert total == length(items)
    end

    test "fetch_monitors/3 returns monitors established by registered name" do
      name = :"process_info_monitored_#{System.unique_integer([:positive])}"
      target = spawn_idle()
      Process.register(target, name)

      pid = spawn_idle(fn -> Process.monitor({name, node()}) end)
      kill_on_exit([pid, target])

      assert {:ok, %{total: 1, truncated?: false, items: [monitor]}} =
               ProcessInfo.fetch_monitors(Node.self(), pid, 1_000)

      assert monitor == {:process, {name, node()}}
    end

    test "fetch_monitored_by/3 returns the monitoring processes" do
      target = spawn_idle()
      watcher = spawn_idle(fn -> Process.monitor(target) end)
      kill_on_exit([watcher, target])

      assert {:ok, %{items: items}} = ProcessInfo.fetch_monitored_by(Node.self(), target, 1_000)
      assert watcher in items
    end

    test "fetch_dictionary/3 returns raw key/value terms" do
      pid =
        spawn_idle(fn ->
          Process.put(:small, :ok)
          Process.put(:tuple, {1, [:a, "b"]})
        end)

      kill_on_exit([pid])

      assert {:ok, %{total: 2, truncated?: false, items: items}} =
               ProcessInfo.fetch_dictionary(Node.self(), pid, 200)

      entries = Map.new(items)

      assert entries[:small] == :ok
      assert entries[:tuple] == {1, [:a, "b"]}
    end

    test "unbounded fetches report the real total when the remote truncates" do
      # 250 entries exceed the requested limit of 200, so the payload is capped
      # while `total` still reflects what the remote actually holds. All four
      # fetches share one remote truncation path, so covering it once is enough.
      pid = spawn_idle(fn -> Enum.each(1..250, &Process.put({:key, &1}, &1)) end)
      kill_on_exit([pid])

      assert {:ok, %{total: total, truncated?: true, items: items}} =
               ProcessInfo.fetch_dictionary(Node.self(), pid, 200)

      assert total >= 250
      assert length(items) == 200
    end

    test "unbounded fetches return {:error, :dead} for a dead pid" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert {:error, :dead} == ProcessInfo.fetch_links(Node.self(), pid, 1_000)
      assert {:error, :dead} == ProcessInfo.fetch_monitors(Node.self(), pid, 1_000)
      assert {:error, :dead} == ProcessInfo.fetch_monitored_by(Node.self(), pid, 1_000)
      assert {:error, :dead} == ProcessInfo.fetch_dictionary(Node.self(), pid, 200)
    end
  end

  describe "unbounded fetches with non-pid input" do
    test "return {:error, :not_a_pid}" do
      assert {:error, :not_a_pid} == ProcessInfo.fetch_links(:demo@localhost, nil, 1_000)
      assert {:error, :not_a_pid} == ProcessInfo.fetch_monitors(:demo@localhost, nil, 1_000)
      assert {:error, :not_a_pid} == ProcessInfo.fetch_monitored_by(:demo@localhost, nil, 1_000)
      assert {:error, :not_a_pid} == ProcessInfo.fetch_dictionary(:demo@localhost, nil, 200)
    end
  end

  describe "unbounded fetch error translation" do
    test "surfaces a missing agent as a remote :undef exception" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :voyager_agent,
                                         :proc_links,
                                         [_pid, _limit],
                                         _timeout ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} ==
               ProcessInfo.fetch_links(:demo@localhost, self(), 1_000)
    end
  end

  # Spawns a process that runs `setup_fun` (e.g. to seed its dictionary),
  # signals readiness, then parks forever so `fetch/2` can inspect it.
  defp spawn_idle(setup_fun \\ fn -> :ok end) do
    parent = self()

    pid =
      spawn(fn ->
        setup_fun.()
        send(parent, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready
    pid
  end

  defp kill_on_exit(pids) do
    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)
  end
end
