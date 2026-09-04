defmodule VoyagerAgentTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Test.VoyagerAgentFixture

  @agent_module :voyager_agent

  setup do
    VoyagerAgentFixture.load!()
    :ok
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
end
