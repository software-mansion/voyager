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

    test "entries are sorted by the sort key, descending" do
      mems = Enum.map(:voyager_agent.proc_top([:memory], :memory, 20), & &1.memory)
      assert mems == Enum.sort(mems, :desc)

      reds = Enum.map(:voyager_agent.proc_top([:reductions], :reductions, 20), & &1.reductions)
      assert reds == Enum.sort(reds, :desc)
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
