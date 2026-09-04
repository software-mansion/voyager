defmodule Voyager.Services.Ets.SearchLiveTest do
  use ExUnit.Case, async: false

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Services.Ets.Search
  alias Voyager.Test.EtsTable

  setup do
    Erpc.bind_impl(Voyager.Erpc.Impl)
    :ok
  end

  test "chunk/4 key_eq matches on a live table via MFA" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    :ets.insert(name, {:keep, 1})
    :ets.insert(name, {:skip, 2})

    assert {:ok, chunk} = Search.chunk(Node.self(), name, {:key_eq, :keep}, 10)
    assert chunk.via == :mfa
    assert chunk.records == [{:keep, 1}]
    assert chunk.continuation == nil
  end

  test "chunk/4 key_prefix matches binary keys that start with the prefix" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    :ets.insert(name, {<<"alpha">>, 1})
    :ets.insert(name, {<<"alpine">>, 2})
    :ets.insert(name, {<<"beta">>, 3})

    assert {:ok, chunk} = Search.chunk(Node.self(), name, {:key_prefix, <<"alp">>}, 10)
    assert chunk.via == :mfa
    keys = MapSet.new(Enum.map(chunk.records, &elem(&1, 0)))
    assert keys == MapSet.new([<<"alpha">>, <<"alpine">>])
  end

  test "chunk/4 element_eq matches a non-key field" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    :ets.insert(name, {:a, :target})
    :ets.insert(name, {:b, :other})

    assert {:ok, chunk} = Search.chunk(Node.self(), name, {:element_eq, 2, :target}, 10)
    assert chunk.records == [{:a, :target}]
  end

  test "chunk/4 key_eq uses keypos 2 from table info" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set, {:keypos, 2}])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    :ets.insert(name, {:ignored, :the_key, :val})
    :ets.insert(name, {:ignored, :other, :no})

    assert {:ok, chunk} = Search.chunk(Node.self(), name, {:key_eq, :the_key}, 10)
    assert chunk.records == [{:ignored, :the_key, :val}]
  end

  test "chunk/4 MFA continuation is :cannot_page" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    for i <- 1..25, do: :ets.insert(name, {i, :hit})

    assert {:ok, page} = Search.chunk(Node.self(), name, {:element_eq, 2, :hit}, 10)
    assert page.via == :mfa
    assert length(page.records) == 10
    assert page.continuation

    assert {:error, :cannot_page} =
             Search.chunk(Node.self(), name, {:element_eq, 2, :hit}, 10, page.continuation)
  end

  test "chunk/4 cannot read a private table owned by another process" do
    pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
    tid = Agent.get(pid, & &1)

    assert {:error, :cannot_read} = Search.chunk(Node.self(), tid, {:element_eq, 1, :k}, 10)
  end

  test "Fetch.select_spec/4 sanitizes matching records on the MFA path" do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> EtsTable.safe_delete(name) end)

    blob = :binary.copy(<<"z">>, 600)
    :ets.insert(name, {:row, blob})
    {:ok, spec} = Search.compile({:key_eq, :row})

    assert {:ok, chunk} = Fetch.select_spec(Node.self(), name, spec, 10)
    assert chunk.via == :mfa
    assert chunk.records == [{:row, Sanitize.term(blob)}]
  end
end
