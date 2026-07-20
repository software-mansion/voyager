defmodule Voyager.Services.NodeInfoTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.NodeInfo
  alias Voyager.Services.NodeInfo.Language
  alias Voyager.Services.NodeInfo.Limits
  alias Voyager.Services.NodeInfo.Memory
  alias Voyager.Services.NodeInfo.RunningApplication
  alias Voyager.Services.NodeInfo.RunQueues
  alias Voyager.Services.NodeInfo.Schedulers
  alias Voyager.Services.NodeInfo.Snapshot
  alias Voyager.Services.NodeInfo.Statistics
  alias Voyager.Services.NodeInfo.SystemInfo

  # test_helper sets the global :erpc impl to the Mox mock; this is a real
  # integration test against the local node, so opt back into the live impl.
  setup do
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, Voyager.ErpcMock) end)
    :ok
  end

  describe "fetch/2" do
    test "returns a populated snapshot for the local node" do
      assert {:ok, %Snapshot{} = snapshot} = NodeInfo.fetch(Node.self())

      assert snapshot.node == Node.self()
      assert %DateTime{} = snapshot.collected_at
      assert %SystemInfo{} = snapshot.system
      assert %Memory{} = snapshot.memory
      assert %Statistics{} = snapshot.runtime
      assert %Limits{} = snapshot.limits
      assert %Schedulers{} = snapshot.schedulers
      assert %RunQueues{} = snapshot.run_queues
    end

    test "languages is a list of Language structs including Elixir" do
      assert {:ok, %Snapshot{languages: languages}} = NodeInfo.fetch(Node.self())

      assert is_list(languages)
      assert Enum.all?(languages, &match?(%Language{}, &1))
      assert Enum.any?(languages, &(&1.name == "Elixir"))
    end

    test "applications is a sorted list of RunningApplication structs including :kernel" do
      assert {:ok, %Snapshot{applications: applications}} = NodeInfo.fetch(Node.self())

      assert is_list(applications)
      assert Enum.all?(applications, &match?(%RunningApplication{}, &1))
      assert Enum.any?(applications, &(&1.name == :kernel))
      assert applications == Enum.sort_by(applications, & &1.name)
    end

    test "system fields are populated from :erlang.system_info/1" do
      assert {:ok, %Snapshot{system: system}} = NodeInfo.fetch(Node.self())

      assert is_binary(system.otp_release)
      assert is_binary(system.erts_version)
      assert is_binary(system.system_version)
      assert is_binary(system.system_architecture)
      assert is_integer(system.wordsize) and system.wordsize > 0
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

    test "returns :noconnection for an unreachable node without crashing the caller" do
      assert {:error, :noconnection} = NodeInfo.fetch(:"nonexistent@127.0.0.1")
    end
  end
end
