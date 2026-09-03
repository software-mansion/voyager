defmodule VoyagerAgentEtsTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Test.EtsSanitizeFixture
  alias Voyager.Test.EtsTable
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module :voyager_agent

  setup do
    Erpc.bind_impl(Voyager.Erpc.Impl)
    VoyagerAgentFixture.load!()
    :ok
  end

  describe "truncate_term/1" do
    test "matches the shared fixture of sample terms" do
      for {input, expected} <- EtsSanitizeFixture.samples() do
        assert @agent_module.truncate_term(input) == expected
      end
    end

    test "is idempotent on fixture outputs" do
      for {_input, expected} <- EtsSanitizeFixture.samples() do
        assert @agent_module.truncate_term(expected) == expected
      end
    end

    test "copies an oversized binary prefix off the parent refc binary" do
      huge = :binary.copy(<<"a">>, 4096)
      marker = Sanitize.marker()
      cap = Sanitize.max_binary_bytes()

      assert {^marker, :binary, prefix, 4096} = @agent_module.truncate_term(huge)
      assert byte_size(prefix) == cap
      assert :binary.referenced_byte_size(prefix) == cap
    end
  end

  describe "ets_select_chunk/3 and ets_lookup/2" do
    test "do not require the gen_server to be registered" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)
      :ets.insert(name, {:k, 1})

      assert Process.whereis(@agent_module) == nil
      assert [{:k, 1}] = @agent_module.ets_lookup(name, :k)
      assert {:ok, %{via: :agent, records: [{:k, 1}]}} = Remote.lookup(Node.self(), name, :k)
    end

    test "truncates records and leaves the ETS continuation opaque" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      blob = :binary.copy(<<"a">>, 600)

      for i <- 1..25, do: :ets.insert(name, {i, blob})

      truncated = Sanitize.term(blob)

      assert {records, cont} = @agent_module.ets_select_chunk(name, 10, :undefined)
      assert length(records) == 10
      assert Enum.all?(records, fn {_i, value} -> value == truncated end)
      refute match?({:"$voyager_truncated", _, _, _}, cont)

      assert {more, cont2} = @agent_module.ets_select_chunk(name, 10, cont)
      assert length(more) == 10
      assert Enum.all?(more, fn {_i, value} -> value == truncated end)

      assert {last, cont3} = @agent_module.ets_select_chunk(name, 10, cont2)
      assert length(last) == 5
      assert Enum.all?(last, fn {_i, value} -> value == truncated end)
      refute match?({:"$voyager_truncated", _, _, _}, cont3)

      assert :"$end_of_table" = @agent_module.ets_select_chunk(name, 10, cont3)
    end

    test "pages through Remote after the first chunk" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      for i <- 1..25, do: :ets.insert(name, {i, i})

      assert {:ok, page} = Remote.select_chunk(Node.self(), name, 10)
      assert page.via == :agent
      assert length(page.records) == 10
      assert page.continuation

      assert {:ok, page2} = Remote.select_chunk(Node.self(), name, 10, page.continuation)
      assert page2.via == :agent
      assert length(page2.records) == 10
      assert page2.continuation

      assert {:ok, page3} = Remote.select_chunk(Node.self(), name, 10, page2.continuation)
      assert page3.via == :agent
      assert length(page3.records) == 5
      assert page3.continuation

      assert {:ok, page4} = Remote.select_chunk(Node.self(), name, 10, page3.continuation)
      assert page4.via == :agent
      assert page4.records == []
      assert page4.continuation == nil
    end

    test "returns '$end_of_table' for an empty table" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      assert :"$end_of_table" = @agent_module.ets_select_chunk(name, 10, :undefined)

      assert {:ok, %{records: [], continuation: nil, via: :agent}} =
               Remote.select_chunk(Node.self(), name, 10)
    end

    test "lookup truncates a matching record" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      :ets.insert(name, {:k, Enum.to_list(1..60)})

      assert [{:k, truncated}] = @agent_module.ets_lookup(name, :k)
      assert truncated == Sanitize.term(Enum.to_list(1..60))
    end
  end

  describe "Fetch with agent loaded" do
    test "select_chunk/3 and lookup/3 cannot read a private table owned by another process" do
      pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
      tid = Agent.get(pid, & &1)

      assert {:error, :cannot_read} = Fetch.select_chunk(Node.self(), tid, 10)
      assert {:error, :cannot_read} = Fetch.lookup(Node.self(), tid, :k)
    end

    @tag capture_log: true
    test "returns :heap_limit_exceeded when the worker exceeds the target heap cap" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      :ets.insert(name, {:wide, Enum.to_list(1..400_000)})

      assert {:error, :heap_limit_exceeded} = Fetch.lookup(Node.self(), name, :wide, 15_000)
    end
  end
end
