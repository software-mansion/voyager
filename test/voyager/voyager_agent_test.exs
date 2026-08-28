defmodule VoyagerAgentTest do
  @moduledoc """
  The agent lives as Erlang source in `priv/` (it is normally compiled on the
  target node), so we compile and load it here before running.
  """
  use ExUnit.Case, async: false

  setup_all do
    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join("voyager_agent.erl")
      |> String.to_charlist()

    {:ok, mod, bin} = :compile.file(path, [:binary])
    {:module, ^mod} = :code.load_binary(mod, path, bin)
    :ok
  end

  describe "proc_top/3" do
    test "returns at most `limit` entries" do
      assert {rows, _total} = :voyager_agent.proc_top([:memory], :memory, 3, :desc, :undefined)
      assert length(rows) == 3

      assert {[_entry], _total} =
               :voyager_agent.proc_top([:memory], :memory, 1, :desc, :undefined)
    end

    test "returns an empty list for a non-positive limit" do
      assert {[], total} = :voyager_agent.proc_top([:memory], :memory, 0, :desc, :undefined)
      assert total > 0
    end

    test "restores the caller's max_heap_size instead of leaving it capped" do
      before = Process.info(self(), :max_heap_size)
      {_rows, _total} = :voyager_agent.proc_top([:memory], :memory, 5, :desc, :undefined)
      assert Process.info(self(), :max_heap_size) == before
    end

    test "returns the total process count alongside the entries" do
      assert {rows, total} = :voyager_agent.proc_top([:memory], :memory, 5, :desc, :undefined)
      assert is_integer(total)
      assert total > 0
      assert total >= length(rows)
    end

    test "each entry is a map carrying :pid plus the requested attributes" do
      assert {[entry | _], _total} =
               :voyager_agent.proc_top([:memory, :reductions], :memory, 5, :desc, :undefined)

      assert is_map(entry)
      assert is_pid(entry.pid)
      assert is_integer(entry.memory)
      assert is_integer(entry.reductions)
      assert entry |> Map.keys() |> Enum.sort() == [:memory, :pid, :reductions]
    end

    test "sorts descending (largest first) with direction :desc" do
      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 20, :desc, :undefined)
      mems = Enum.map(rows, & &1.memory)
      assert mems == Enum.sort(mems, :desc)
    end

    test "sorts ascending (smallest first) with direction :asc" do
      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 20, :asc, :undefined)
      mems = Enum.map(rows, & &1.memory)
      assert mems == Enum.sort(mems, :asc)
    end

    test ":asc keeps the smallest values, not the largest" do
      # The smallest-N by memory must not exceed the largest-N by memory.
      {asc_rows, _} = :voyager_agent.proc_top([:memory], :memory, 10, :asc, :undefined)
      {desc_rows, _} = :voyager_agent.proc_top([:memory], :memory, 10, :desc, :undefined)
      asc = Enum.map(asc_rows, & &1.memory)
      desc = Enum.map(desc_rows, & &1.memory)
      assert Enum.max(asc) <= Enum.min(desc)
    end

    test "an undefined search applies no filter" do
      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, :undefined)
      assert self() in Enum.map(rows, & &1.pid)
    end

    test "filters by a registered name (case-insensitive substring)" do
      # self() is auto-unregistered when this test process exits.
      name = :voyager_agent_test_needle
      Process.register(self(), name)

      attrs = [:memory, :registered_name]

      {matched, _} =
        :voyager_agent.proc_top(attrs, :memory, 1_000_000, :desc, "AGENT_TEST_NEEDLE")

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

      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, pid_fragment)
      assert self() in Enum.map(rows, & &1.pid)
    end

    test "a search matching nothing returns an empty list" do
      assert {[], _total} =
               :voyager_agent.proc_top(
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

      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, needle)
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
      {rows, _} = :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, :undefined)
      assert hog in Enum.map(rows, & &1.pid)
    end
  end
end
