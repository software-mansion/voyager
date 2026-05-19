defmodule Voyager.NodeInfoTest do
  use ExUnit.Case, async: true

  alias Voyager.NodeInfo

  alias Voyager.NodeInfo.{
    Language,
    Limits,
    Memory,
    Processors,
    RunQueues,
    Schedulers,
    Snapshot,
    Statistics,
    SystemInfo
  }

  describe "fetch/2" do
    test "returns a populated snapshot for the local node" do
      assert {:ok, %Snapshot{} = snapshot} = NodeInfo.fetch(Node.self())

      assert snapshot.node == Node.self()
      assert %DateTime{} = snapshot.collected_at
      assert %SystemInfo{} = snapshot.system
      assert %Memory{} = snapshot.memory
      assert %Statistics{} = snapshot.runtime
      assert %Limits{} = snapshot.limits
      assert %Processors{} = snapshot.processors
      assert %Schedulers{} = snapshot.schedulers
      assert %RunQueues{} = snapshot.run_queues
    end

    test "languages is a list of Language structs including Elixir" do
      assert {:ok, %Snapshot{languages: languages}} = NodeInfo.fetch(Node.self())

      assert is_list(languages)
      assert Enum.all?(languages, &match?(%Language{}, &1))
      assert Enum.any?(languages, &(&1.name == "Elixir"))
    end

    test "system fields are populated from :erlang.system_info/1" do
      assert {:ok, %Snapshot{system: system}} = NodeInfo.fetch(Node.self())

      assert is_binary(system.otp_release)
      assert is_binary(system.erts_version)
      assert is_binary(system.system_version)
      assert is_binary(system.system_architecture)
      assert is_integer(system.wordsize_internal) and system.wordsize_internal > 0
      assert is_integer(system.wordsize_external) and system.wordsize_external > 0
      assert is_boolean(system.smp_support?)
      assert is_boolean(system.thread_support?)
      assert is_integer(system.async_threads) and system.async_threads >= 0
    end

    test "memory totals are non-negative integers" do
      assert {:ok, %Snapshot{memory: memory}} = NodeInfo.fetch(Node.self())

      for field <- [
            :total,
            :processes_allocated,
            :processes_used,
            :atom_allocated,
            :atom_used,
            :binary,
            :code,
            :ets,
            :other
          ] do
        value = Map.fetch!(memory, field)
        assert is_integer(value), "expected #{field} to be an integer, got: #{inspect(value)}"
        assert value >= 0, "expected #{field} to be non-negative, got: #{value}"
      end
    end

    test "returns an error tuple for an unreachable node without crashing the caller" do
      assert {:error, {:error, {:erpc, :noconnection}}} =
               NodeInfo.fetch(:"nonexistent@127.0.0.1")
    end
  end
end
