defmodule Voyager.Services.Ets.RemoteLiveTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.Ets.Remote

  setup do
    prev = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)

    on_exit(fn -> Application.put_env(:voyager, :erpc, prev) end)

    :ok
  end

  test "list/1 returns live local tables with memory in bytes" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    assert {:ok, tables} = Remote.list(Node.self())
    table = Enum.find(tables, &(&1.id == name))

    assert table
    assert table.name == name
    assert table.named_table
    assert table.protection == :public
    assert table.type == :set
    assert table.owner == self()

    words = :ets.info(name, :memory)
    wordsize = :erlang.system_info(:wordsize)
    assert table.memory == words * wordsize
  end

  test "list/1 includes a private table owned by another process" do
    pid = start_supervised!({Agent, fn -> :ets.new(unique_name(), [:private]) end})
    tid = Agent.get(pid, & &1)

    assert {:ok, tables} = Remote.list(Node.self())
    table = Enum.find(tables, &(&1.id == tid))

    assert table
    assert table.protection == :private
    assert table.owner == pid
    assert is_reference(table.id)
  end

  test "info/2 fetches a named table and :not_found after delete" do
    name = unique_name()
    :ets.new(name, [:named_table, :public])
    on_exit(fn -> safe_delete(name) end)

    assert {:ok, info} = Remote.info(Node.self(), name)
    assert info.id == name
    assert info.named_table

    :ets.delete(name)
    assert {:error, :not_found} = Remote.info(Node.self(), name)
  end

  test "list/1 uses the unnamed table reference as the handle" do
    tid = :ets.new(unique_name(), [:public])
    on_exit(fn -> safe_delete(tid) end)

    assert is_reference(tid)
    assert {:ok, tables} = Remote.list(Node.self())
    assert Enum.any?(tables, &(&1.id == tid))
  end

  defp unique_name do
    :"voyager_ets_#{System.unique_integer([:positive])}"
  end

  defp safe_delete(id) do
    :ets.delete(id)
  rescue
    ArgumentError -> :ok
  end
end
