defmodule Voyager.Services.Ets.FetchLiveTest do
  use ExUnit.Case, async: false

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Sanitize

  setup do
    Erpc.bind_impl(Voyager.Erpc.Impl)
    :ok
  end

  test "select_chunk/3 returns sanitized records from a live table" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    blob = :binary.copy(<<"z">>, 600)
    :ets.insert(name, {:row, blob})

    assert {:ok, chunk} = Fetch.select_chunk(Node.self(), name, 10)
    assert chunk.via == :mfa
    assert chunk.records == [{:row, Sanitize.term(blob)}]
  end

  test "lookup/3 returns sanitized records from a live table" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    :ets.insert(name, {:k, Enum.to_list(1..60)})

    assert {:ok, chunk} = Fetch.lookup(Node.self(), name, :k)
    assert [{:k, truncated}] = chunk.records
    assert truncated == Sanitize.term(Enum.to_list(1..60))
  end

  test "select_chunk/3 leaves the ETS continuation unsanitized" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    for i <- 1..25, do: :ets.insert(name, {i, :binary.copy(<<"a">>, 600)})

    assert {:ok, page} = Fetch.select_chunk(Node.self(), name, 10)
    assert is_list(page.records)
    assert page.continuation
    refute match?({:"$voyager_truncated", _, _, _}, page.continuation)
  end

  test "propagates :cannot_read for a private table owned by another process" do
    pid = start_supervised!({Agent, fn -> :ets.new(unique_name(), [:private]) end})
    tid = Agent.get(pid, & &1)

    assert {:error, :cannot_read} = Fetch.select_chunk(Node.self(), tid, 10)
    assert {:error, :cannot_read} = Fetch.lookup(Node.self(), tid, :k)
  end

  test "returns :heap_limit_exceeded when the copied payload exceeds the host heap cap" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    # 500_000 words is process heap (cons cells), not refc binaries.
    :ets.insert(name, {:wide, Enum.to_list(1..400_000)})

    assert {:error, :heap_limit_exceeded} = Fetch.lookup(Node.self(), name, :wide, 15_000)
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
