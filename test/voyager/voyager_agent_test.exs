defmodule VoyagerAgentTest do
  @moduledoc """
  Exercises the remote agent's `proc_top/3` scan against the local node.

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
      assert length(:voyager_agent.proc_top([:memory], :memory, 3)) == 3
      assert length(:voyager_agent.proc_top([:memory], :memory, 1)) == 1
    end

    test "returns an empty list for a non-positive limit" do
      assert :voyager_agent.proc_top([:memory], :memory, 0) == []
    end

    test "each entry is a map carrying :pid plus the requested attributes" do
      [entry | _] = :voyager_agent.proc_top([:memory, :reductions], :memory, 5)

      assert is_map(entry)
      assert is_pid(entry.pid)
      assert is_integer(entry.memory)
      assert is_integer(entry.reductions)
      assert entry |> Map.keys() |> Enum.sort() == [:memory, :pid, :reductions]
    end

    test "defaults to descending order via the /3 arity" do
      mems = Enum.map(:voyager_agent.proc_top([:memory], :memory, 20), & &1.memory)
      assert mems == Enum.sort(mems, :desc)

      reds = Enum.map(:voyager_agent.proc_top([:reductions], :reductions, 20), & &1.reductions)
      assert reds == Enum.sort(reds, :desc)
    end

    test "sorts descending (largest first) with direction :desc" do
      mems = Enum.map(:voyager_agent.proc_top([:memory], :memory, 20, :desc), & &1.memory)
      assert mems == Enum.sort(mems, :desc)
    end

    test "sorts ascending (smallest first) with direction :asc" do
      mems = Enum.map(:voyager_agent.proc_top([:memory], :memory, 20, :asc), & &1.memory)
      assert mems == Enum.sort(mems, :asc)
    end

    test ":asc keeps the smallest values, not the largest" do
      # The smallest-N by memory must not exceed the largest-N by memory.
      asc = Enum.map(:voyager_agent.proc_top([:memory], :memory, 10, :asc), & &1.memory)
      desc = Enum.map(:voyager_agent.proc_top([:memory], :memory, 10, :desc), & &1.memory)
      assert Enum.max(asc) <= Enum.max(desc)
      assert Enum.min(asc) <= Enum.min(desc)
    end

    test "an undefined search applies no filter" do
      pids =
        Enum.map(
          :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, :undefined),
          & &1.pid
        )

      assert self() in pids
    end

    test "filters by a registered name (case-insensitive substring)" do
      # self() is auto-unregistered when this test process exits.
      name = :voyager_agent_test_needle
      Process.register(self(), name)

      attrs = [:memory, :registered_name]

      matched =
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

      pids =
        Enum.map(
          :voyager_agent.proc_top([:memory], :memory, 1_000_000, :desc, pid_fragment),
          & &1.pid
        )

      assert self() in pids
    end

    test "a search matching nothing returns an empty list" do
      assert :voyager_agent.proc_top(
               [:memory, :registered_name],
               :memory,
               100,
               :desc,
               "zzz_no_such_process_zzz"
             ) ==
               []
    end

    test "does not match against numeric attributes" do
      # `1` appears in almost every process's memory/reductions; searching for it
      # must not match numerically-typed attributes.
      attrs = [:memory, :registered_name]

      matched =
        :voyager_agent.proc_top(attrs, :memory, 1_000_000, :desc, "no_numeric_match_9e9e9e")

      assert matched == []
    end

    test "captures a memory-heavy process when the whole table is returned" do
      parent = self()

      hog =
        spawn(fn ->
          big = Enum.to_list(1..200_000)
          send(parent, :ready)

          receive do
            :stop -> big
          end
        end)

      on_exit(fn -> send(hog, :stop) end)
      assert_receive :ready

      # A limit larger than the process count returns every live process.
      pids = Enum.map(:voyager_agent.proc_top([:memory], :memory, 1_000_000), & &1.pid)
      assert hog in pids
    end
  end
end
