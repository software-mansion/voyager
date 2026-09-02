defmodule VoyagerAgentTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}
  @agent_module :voyager_agent
  @agent_filename "voyager_agent.erl"

  setup do
    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join(@agent_filename)
      |> String.to_charlist()

    {:ok, @agent_module, binary} = :compile.file(path, [:binary, :return_errors])
    {:module, @agent_module} = :code.load_binary(@agent_module, path, binary)

    on_exit(fn ->
      case Process.whereis(@agent_module) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          end
      end

      :code.purge(@agent_module)
      :code.delete(@agent_module)
      :code.purge(@agent_module)
    end)
  end

  describe "register/1" do
    test "starts the agent and returns its pid" do
      assert {:ok, pid} = @agent_module.register(Node.self())
      assert pid == Process.whereis(@agent_module)
    end

    test "is idempotent for the same node" do
      assert {:ok, pid} = @agent_module.register(Node.self())
      assert {:ok, ^pid} = @agent_module.register(Node.self())
      assert :sys.get_state(@agent_module) == {:state, %{Node.self() => true}}
    end

    test "restarts instead of exiting when the agent is killed during the call" do
      # Both tasks are start_supervised! so they are cleaned up between tests.
      # The stub holds the agent name and dies from a genuine :kill mid-call.
      stub =
        start_supervised!(
          {Task,
           fn ->
             receive do
               {:"$gen_call", _from, {:register, _node}} -> Process.exit(self(), :kill)
             end
           end},
          id: :agent_stub
        )

      Process.register(stub, @agent_module)
      stub_ref = Process.monitor(stub)
      test_pid = self()

      # The probe calls register/1 in its own process: if the kill escapes the
      # retry, the probe dies and the :normal DOWN assertion below fails
      # showing the escaped reason, instead of crashing this test process.
      probe =
        start_supervised!(
          {Task, fn -> send(test_pid, {:registered, @agent_module.register(Node.self())}) end},
          id: :register_probe
        )

      probe_ref = Process.monitor(probe)

      assert_receive {:DOWN, ^stub_ref, :process, ^stub, :killed}
      assert_receive {:DOWN, ^probe_ref, :process, ^probe, :normal}
      assert_receive {:registered, {:ok, agent}}
      assert agent == Process.whereis(@agent_module)
    end
  end

  describe "exit signals" do
    test "shuts down on an exit signal so terminate/2 can purge the module" do
      {:ok, pid} = @agent_module.register(Node.self())
      ref = Process.monitor(pid)

      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      refute Process.whereis(@agent_module)
      assert false == Code.loaded?(@agent_module)
    end
  end

  describe "nodedown" do
    test "keeps other registrations when one Voyager node goes down" do
      voyager_node = Node.self()
      other = :other@localhost
      {:ok, pid} = @agent_module.register(voyager_node)

      :sys.replace_state(pid, fn {:state, nodes} ->
        {:state, Map.put(nodes, other, true)}
      end)

      send(pid, {:nodedown, voyager_node})
      _ = :sys.get_state(pid)

      assert Process.whereis(@agent_module) == pid
      assert :sys.get_state(pid) == {:state, %{other => true}}
      assert Code.loaded?(@agent_module)
    end

    test "stops and unloads the module when the last Voyager node goes down" do
      voyager_node = Node.self()
      {:ok, pid} = @agent_module.register(voyager_node)
      ref = Process.monitor(pid)

      send(pid, {:nodedown, voyager_node})

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      refute Process.whereis(@agent_module)
      assert false == Code.loaded?(@agent_module)
    end
  end

  describe "proc_top/5" do
    test "returns at most `limit` entries" do
      assert {rows, _total} = @agent_module.proc_top([:memory], :memory, 3, :desc, :undefined)
      assert length(rows) == 3

      assert {[_entry], _total} =
               @agent_module.proc_top([:memory], :memory, 1, :desc, :undefined)
    end

    test "returns an empty list for a non-positive limit" do
      assert {[], total} = @agent_module.proc_top([:memory], :memory, 0, :desc, :undefined)
      assert total > 0
    end

    test "restores the caller's max_heap_size instead of leaving it capped" do
      before = Process.info(self(), :max_heap_size)
      {_rows, _total} = @agent_module.proc_top([:memory], :memory, 5, :desc, :undefined)
      assert Process.info(self(), :max_heap_size) == before
    end

    test "returns the total process count alongside the entries" do
      assert {rows, total} = @agent_module.proc_top([:memory], :memory, 5, :desc, :undefined)
      assert is_integer(total)
      assert total > 0
      assert total >= length(rows)
    end

    test "each entry is a map carrying :pid plus the requested attributes" do
      assert {[entry | _], _total} =
               @agent_module.proc_top([:memory, :reductions], :memory, 5, :desc, :undefined)

      assert is_map(entry)
      assert is_pid(entry.pid)
      assert is_integer(entry.memory)
      assert is_integer(entry.reductions)
      assert entry |> Map.keys() |> Enum.sort() == [:memory, :pid, :reductions]
    end

    test "sorts descending (largest first) with direction :desc" do
      {rows, _} = @agent_module.proc_top([:memory], :memory, 20, :desc, :undefined)
      mems = Enum.map(rows, & &1.memory)
      assert mems == Enum.sort(mems, :desc)
    end

    test "sorts ascending (smallest first) with direction :asc" do
      {rows, _} = @agent_module.proc_top([:memory], :memory, 20, :asc, :undefined)
      mems = Enum.map(rows, & &1.memory)
      assert mems == Enum.sort(mems, :asc)
    end

    test ":asc keeps the smallest values, not the largest" do
      # The smallest-N by memory must not exceed the largest-N by memory.
      {asc_rows, _} = @agent_module.proc_top([:memory], :memory, 10, :asc, :undefined)
      {desc_rows, _} = @agent_module.proc_top([:memory], :memory, 10, :desc, :undefined)
      asc = Enum.map(asc_rows, & &1.memory)
      desc = Enum.map(desc_rows, & &1.memory)
      assert Enum.max(asc) <= Enum.min(desc)
    end

    test "an undefined search applies no filter" do
      {rows, _} = @agent_module.proc_top([:memory], :memory, 1_000_000, :desc, :undefined)
      assert self() in Enum.map(rows, & &1.pid)
    end

    test "filters by a registered name (case-insensitive substring)" do
      # self() is auto-unregistered when this test process exits.
      name = :voyager_agent_test_needle
      Process.register(self(), name)

      attrs = [:memory, :registered_name]

      {matched, _} =
        @agent_module.proc_top(attrs, :memory, 1_000_000, :desc, "AGENT_TEST_NEEDLE")

      names = Enum.map(matched, & &1.registered_name)
      assert name in names
      assert Enum.all?(names, &(&1 != []))
    end

    test "filters by pid" do
      pid_fragment =
        self()
        |> :erlang.pid_to_list()
        |> to_string()
        |> String.trim_leading("<")
        |> String.trim_trailing(">")

      {rows, _} = @agent_module.proc_top([:memory], :memory, 1_000_000, :desc, pid_fragment)
      assert self() in Enum.map(rows, & &1.pid)
    end

    test "a search matching nothing returns an empty list" do
      assert {[], _total} =
               @agent_module.proc_top(
                 [:memory, :registered_name],
                 :memory,
                 100,
                 :desc,
                 "zzz_no_such_process_zzz"
               )
    end

    test "does not match against numeric attribute values" do
      parent = self()

      hog =
        start_supervised!(
          {Task,
           fn ->
             big = Enum.to_list(1..50_000)
             send(parent, {:ready, self()})

             receive do
               :stop -> big
             end
           end}
        )

      on_exit(fn -> send(hog, :stop) end)
      assert_receive {:ready, ^hog}

      # `hog`'s memory is a many-digit integer that cannot appear in a pid
      # string, so if the search matched it that could only be via the numeric
      # :memory attribute — which contains/2 must skip.
      {:memory, mem} = Process.info(hog, :memory)
      needle = Integer.to_string(mem)

      {rows, _} = @agent_module.proc_top([:memory], :memory, 1_000_000, :desc, needle)
      refute hog in Enum.map(rows, & &1.pid)
    end

    test "captures a memory-heavy process when the whole table is returned" do
      parent = self()

      hog =
        start_supervised!(
          {Task,
           fn ->
             big = Enum.to_list(1..200_000)
             send(parent, {:ready, self()})

             receive do
               :stop -> big
             end
           end}
        )

      on_exit(fn -> send(hog, :stop) end)
      assert_receive {:ready, ^hog}

      # A limit larger than the process count returns every live process.
      {rows, _} = @agent_module.proc_top([:memory], :memory, 1_000_000, :desc, :undefined)
      assert hog in Enum.map(rows, & &1.pid)
    end
  end

  # The term walk is only reachable through the public reads, so it is exercised
  # via proc_dictionary/3 -- the cheapest way to hand the agent an arbitrary term.
  describe "term truncation" do
    test "returns a term under budget unchanged" do
      term = %{a: [1, 2, {:x, <<"hi">>}], b: :ok}

      assert {term, false} == bound(term, 1_000)
    end

    test "elides past the budget instead of descending" do
      deep = Enum.reduce(1..1_000, :bottom, fn _, acc -> [acc] end)

      assert {bounded, true} = bound(deep, 10)
      assert bounded == [[[[[[[[[[:"$voyager_truncated"]]]]]]]]]]
    end

    test "caps a wide list and marks the cut" do
      assert {bounded, true} = bound(Enum.to_list(1..1_000), 20)
      assert length(bounded) == 20
      assert List.last(bounded) == :"$voyager_truncated"
    end

    test "caps a wide map with a marker entry" do
      wide = Map.new(1..1_000, &{&1, &1})

      assert {bounded, true} = bound(wide, 20)
      assert map_size(bounded) < 1_000
      assert Map.has_key?(bounded, :"$voyager_truncated")
    end

    test "caps a wide tuple by index" do
      wide = List.to_tuple(Enum.to_list(1..1_000))

      assert {bounded, true} = bound(wide, 20)
      assert tuple_size(bounded) == 20
      assert elem(bounded, 19) == :"$voyager_truncated"
    end

    test "keeps an improper list improper" do
      assert {bounded, false} = bound([1, 2 | :tail], 100)
      assert bounded == [1, 2 | :tail]
    end

    test "caps a binary larger than the byte limit" do
      assert {bounded, true} = bound(:binary.copy("x", 100_000), 10_000)
      assert byte_size(bounded) == 4_096
    end

    test "caps a binary to the remaining budget when it is smaller than the byte limit" do
      assert {bounded, true} = bound(:binary.copy("x", 100_000), 100)
      assert byte_size(bounded) == 100
    end

    test "drops an oversized non-byte-aligned bitstring whole" do
      bits = <<:binary.copy("x", 100_000)::binary, 1::size(1)>>

      assert {:"$voyager_truncated", true} == bound(bits, 100)
    end

    test "keeps an already-truncated flag true across a later untruncated binary" do
      assert {[cut, "small"], true} = bound([:binary.copy("x", 5_000), "small"], 10_000)
      assert byte_size(cut) == 4_096
    end

    test "charges at least one unit for an empty binary instead of walking it for free" do
      assert {bounded, true} = bound(List.duplicate(<<>>, 1_000), 20)
      assert length(bounded) < 1_000
    end

    test "drops the entry list to empty at budget zero instead of a bare marker" do
      assert {:ok, %{truncated: true, items: []}} =
               @agent_module.proc_dictionary(self(), 1_000, 0)
    end

    test "restores the caller's max_heap_size instead of leaving it capped" do
      before = Process.info(self(), :max_heap_size)
      @agent_module.proc_dictionary(self(), 10, 10)
      assert Process.info(self(), :max_heap_size) == before
    end
  end

  describe "proc_state/3" do
    test "returns the state of an OTP-behaviour process" do
      state = %{count: 1, items: [:a, :b]}
      pid = start_supervised!({Agent, fn -> state end})

      assert {:ok, %{term: ^state, truncated: false}} = @agent_module.proc_state(pid, 1_000, 500)
    end

    test "truncates a state that exceeds the budget" do
      pid = start_supervised!({Agent, fn -> Enum.to_list(1..1_000) end})

      assert {:ok, %{term: term, truncated: true}} = @agent_module.proc_state(pid, 20, 500)
      assert List.last(term) == :"$voyager_truncated"
    end

    # A raw process never answers the system message, which is also what a busy
    # OTP process looks like from here -- both are reported as a timeout.
    test "times out for a process that does not handle system messages" do
      pid = spawn_idle()
      kill_on_exit([pid])

      assert {:error, :timeout} == @agent_module.proc_state(pid, 1_000, 50)
    end

    test "returns {:error, :dead} for a dead pid" do
      assert {:error, :dead} == @agent_module.proc_state(dead_pid(), 1_000, 500)
    end
  end

  describe "proc_messages/3" do
    test "caps the mailbox at the limit while reporting the real total" do
      pid = spawn_idle()
      kill_on_exit([pid])
      Enum.each(1..10, &send(pid, {:msg, &1}))

      assert {:ok, %{total: 10, truncated: true, items: items}} =
               @agent_module.proc_messages(pid, 3, 1_000)

      assert items == [{:msg, 1}, {:msg, 2}, {:msg, 3}]
    end

    test "truncates an oversized single message" do
      pid = spawn_idle()
      kill_on_exit([pid])
      send(pid, {:big, Enum.to_list(1..1_000)})

      assert {:ok, %{total: 1, truncated: true, items: [{:big, value}]}} =
               @agent_module.proc_messages(pid, 10, 20)

      assert List.last(value) == :"$voyager_truncated"
    end

    test "returns an empty mailbox untruncated" do
      pid = spawn_idle()
      kill_on_exit([pid])

      assert {:ok, %{total: 0, truncated: false, items: []}} ==
               @agent_module.proc_messages(pid, 10, 1_000)
    end

    test "returns {:error, :dead} for a dead pid" do
      assert {:error, :dead} == @agent_module.proc_messages(dead_pid(), 10, 1_000)
    end
  end

  # Hands `term` to the agent as the sole dictionary entry of a throwaway
  # process, so the budget is spent on `term` and nothing else. Each entry is
  # budgeted on its own (the entry list itself is free), so walking to the
  # value costs 2 terms first -- the `{key, value}` tuple and the key -- which
  # `@probe_overhead` pays for.
  @probe_overhead 2
  defp bound(term, budget) do
    parent = self()

    pid =
      spawn(fn ->
        Process.put(:probe, term)
        send(parent, :ready)

        receive do
          :never -> :ok
        end
      end)

    kill_on_exit([pid])
    assert_receive :ready

    assert {:ok, %{items: items, truncated: truncated}} =
             @agent_module.proc_dictionary(pid, 1_000, budget + @probe_overhead)

    case items do
      [{:probe, value}] -> {value, truncated}
      [marker] -> {marker, truncated}
    end
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  defp kill_on_exit(pids) do
    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)
  end
end
