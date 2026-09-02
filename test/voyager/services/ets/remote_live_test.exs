defmodule Voyager.Services.Ets.RemoteLiveTest do
  use ExUnit.Case, async: false

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Remote

  setup do
    Erpc.bind_impl(Voyager.Erpc.Impl)
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

  test "select_chunk/3 MFA first page; a continuation is :cannot_page" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    for i <- 1..25, do: :ets.insert(name, {i, i})

    assert {:ok, chunk} = Remote.select_chunk(Node.self(), name, 10)
    assert chunk.via == :mfa
    assert length(chunk.records) == 10
    assert chunk.continuation

    assert {:error, :cannot_page} =
             Remote.select_chunk(Node.self(), name, 10, chunk.continuation)
  end

  test "an :ets.select/3 continuation is invalid after an ETF round-trip" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    for i <- 1..25, do: :ets.insert(name, {i, i})

    {_records, continuation} = :ets.select(name, [{:"$1", [], [:"$1"]}], 10)
    broken = :erlang.binary_to_term(:erlang.term_to_binary(continuation))

    assert_raise ArgumentError, fn -> :ets.select(broken) end
  end

  test "lookup/3 fetches a named table by atom, integer, and binary keys" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    :ets.insert(name, {:atom_key, 1})
    :ets.insert(name, {7, 2})
    :ets.insert(name, {<<"bin">>, 3})

    assert {:ok, %{records: [{:atom_key, 1}], via: :mfa}} =
             Remote.lookup(Node.self(), name, :atom_key)

    assert {:ok, %{records: [{7, 2}]}} = Remote.lookup(Node.self(), name, 7)
    assert {:ok, %{records: [{<<"bin">>, 3}]}} = Remote.lookup(Node.self(), name, <<"bin">>)
  end

  test "select_chunk/3 and lookup/3 use an unnamed table reference as the handle" do
    tid = :ets.new(unique_name(), [:public])
    on_exit(fn -> safe_delete(tid) end)
    :ets.insert(tid, {:k, 1})

    assert is_reference(tid)
    assert {:ok, %{records: [{:k, 1}]}} = Remote.lookup(Node.self(), tid, :k)

    assert {:ok, %{records: [{:k, 1}], via: :mfa}} =
             Remote.select_chunk(Node.self(), tid, 10)
  end

  test "select_chunk/3 cannot read a private table owned by another process" do
    pid = start_supervised!({Agent, fn -> :ets.new(unique_name(), [:private]) end})
    tid = Agent.get(pid, & &1)

    assert {:error, :cannot_read} = Remote.select_chunk(Node.self(), tid, 10)
    assert {:error, :cannot_read} = Remote.lookup(Node.self(), tid, :k)
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
