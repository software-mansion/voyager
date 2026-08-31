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

    test "restarts instead of exiting when the agent dies during the call" do
      # Stand in for the agent so the name is registered and whereis/1 succeeds,
      # then die without replying. That is the race window: register/1 has
      # already committed to do_register/2 when the process disappears.
      stub =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:register, _node}} -> exit(:normal)
          end
        end)

      Process.register(stub, @agent_module)
      ref = Process.monitor(stub)

      assert {:ok, pid} = @agent_module.register(Node.self())

      assert_receive {:DOWN, ^ref, :process, ^stub, :normal}
      assert is_pid(pid)
      assert pid == Process.whereis(@agent_module)
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
    test "keeps other registrations when one parent goes down" do
      parent = Node.self()
      other = :other@localhost
      {:ok, pid} = @agent_module.register(parent)

      :sys.replace_state(pid, fn {:state, nodes} ->
        {:state, Map.put(nodes, other, true)}
      end)

      send(pid, {:nodedown, parent})
      _ = :sys.get_state(pid)

      assert Process.whereis(@agent_module) == pid
      assert :sys.get_state(pid) == {:state, %{other => true}}
      assert Code.loaded?(@agent_module)
    end

    test "stops and unloads the module when the last parent goes down" do
      parent = Node.self()
      {:ok, pid} = @agent_module.register(parent)
      ref = Process.monitor(pid)

      send(pid, {:nodedown, parent})

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
