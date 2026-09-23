defmodule VoyagerAgentEtsTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Services.Ets.Search
  alias Voyager.Test.EtsTable
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module :voyager_agent
  @marker :"$voyager_truncated"
  @skip :"$voyager_skip"
  @budget Voyager.Agent.default_budget()

  setup do
    VoyagerAgentFixture.load!()
    :ok
  end

  describe "ets_select_chunk/4" do
    test "walks each record with the budget and leaves the ETS continuation opaque" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      blob = :binary.copy(<<"a">>, 10_000)

      for i <- 1..25, do: :ets.insert(name, {i, blob})

      assert {:ok, %{records: records, continuation: cont, truncated: true}} =
               @agent_module.ets_select_chunk(name, 10, 50, :undefined)

      assert length(records) == 10

      assert Enum.all?(records, fn {_i, value} ->
               is_binary(value) and byte_size(value) < 10_000
             end)

      refute match?({@marker, _, _, _}, cont)
      refute cont in [:undefined, :"$end_of_table"]

      assert {:ok, %{records: more, continuation: cont2, truncated: true}} =
               @agent_module.ets_select_chunk(name, 10, 50, cont)

      assert length(more) == 10
      assert Enum.all?(more, fn {_i, value} -> is_binary(value) and byte_size(value) < 10_000 end)
      refute match?({@marker, _, _, _}, cont2)

      assert {:ok, %{records: last, continuation: :undefined, truncated: true}} =
               @agent_module.ets_select_chunk(name, 10, 50, cont2)

      assert length(last) == 5
    end

    test "keeps the page length at Limit when the budget is zero" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      for i <- 1..10, do: :ets.insert(name, {i, i})

      assert {:ok, %{records: records, truncated: true}} =
               @agent_module.ets_select_chunk(name, 10, 0, :undefined)

      assert length(records) == 10
      assert Enum.all?(records, &(&1 == @marker))
    end

    test "pages through a table larger than the chunk size" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      for i <- 1..25, do: :ets.insert(name, {i, i})

      assert {:ok, %{records: page, continuation: cont, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, :undefined)

      assert length(page) == 10
      assert cont not in [:undefined, :"$end_of_table"]

      assert {:ok, %{records: page2, continuation: cont2, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, cont)

      assert length(page2) == 10
      assert cont2 not in [:undefined, :"$end_of_table"]

      assert {:ok, %{records: page3, continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, cont2)

      assert length(page3) == 5
    end

    test "maps a table smaller than the chunk size to an undefined continuation" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      for i <- 1..3, do: :ets.insert(name, {i, i})

      assert {:ok, %{records: records, continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, :undefined)

      assert length(records) == 3
    end

    test "returns an empty chunk for an empty table" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      assert {:ok, %{records: [], continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, :undefined)
    end

    test "raises badarg for a private table owned by another process" do
      pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
      tid = Agent.get(pid, & &1)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_chunk(tid, 10, @budget, :undefined)
      end
    end

    test "raises badarg for a negative budget" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_chunk(name, 10, -1, :undefined)
      end
    end
  end

  describe "ets_lookup/5" do
    test "pages a duplicate_bag key after an ETF-round-tripped continuation" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :duplicate_bag])
      assert_paged_key_lookup(name)
    end

    test "does not ship leftover bag binaries in the continuation" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :duplicate_bag])
      blob = :binary.copy(<<"a">>, 10_000)
      for _i <- 1..30, do: :ets.insert(name, {:k, blob})

      assert {:ok, %{records: page, continuation: {@skip, 10} = cont, truncated: true}} =
               @agent_module.ets_lookup(name, :k, 10, 50, :undefined)

      assert length(page) == 10
      assert :erlang.external_size(cont) < 10_000

      broken = :erlang.binary_to_term(:erlang.term_to_binary(cont))
      :erlang.garbage_collect()

      assert {:ok, %{records: page2, continuation: {@skip, 20} = cont2, truncated: true}} =
               @agent_module.ets_lookup(name, :k, 10, 50, broken)

      assert length(page2) == 10
      assert :erlang.external_size(cont2) < 10_000
    end

    test "returns at most one row for a set key" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      :ets.insert(name, {:k, 1})
      :ets.insert(name, {:other, 2})

      assert {:ok, %{records: [{:k, 1}], continuation: :undefined, truncated: false}} =
               @agent_module.ets_lookup(name, :k, 10, @budget, :undefined)
    end

    test "looks up a set row wider than 255 elements" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      wide = wide_record(:k, 256)
      :ets.insert(name, wide)

      assert {:ok, %{records: [^wide], continuation: :undefined, truncated: false}} =
               @agent_module.ets_lookup(name, :k, 10, @budget, :undefined)
    end

    test "looks up a bag row wider than 255 elements" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :bag])
      wide = wide_record(:k, 256)
      :ets.insert(name, wide)
      :ets.insert(name, {:other, 1})

      assert {:ok, %{records: [^wide], continuation: :undefined, truncated: false}} =
               @agent_module.ets_lookup(name, :k, 10, @budget, :undefined)
    end

    test "returns both narrow and wide bag rows for the same key" do
      name = mixed_arity_table(:bag)
      assert_lookup_matches_ets(name, :k)
    end

    test "raises badarg for a zero limit" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :bag])

      assert_raise ArgumentError, fn ->
        @agent_module.ets_lookup(name, :k, 0, @budget, :undefined)
      end
    end

    test "does not duplicate a wide row when the key is a match-spec atom" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :bag])
      :ets.insert(name, {:"$1", 1})
      :ets.insert(name, wide_record(:"$1", 256))
      assert_lookup_matches_ets(name, :"$1")
    end

    test "treats match-spec keys as literals" do
      keys = [:"$1", {:"$1", :_}, [:"$1"], %{}]
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :bag])

      for key <- keys, do: :ets.insert(name, {key, :hit})
      :ets.insert(name, {%{a: 1}, :decoy})

      for key <- keys, do: assert_lookup_matches_ets(name, key)
    end

    test "truncates matching bag rows within the page" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :duplicate_bag])

      blob = :binary.copy(<<"a">>, 10_000)
      :ets.insert(name, {:k, blob})
      :ets.insert(name, {:k, blob})

      assert {:ok, %{records: records, continuation: :undefined, truncated: true}} =
               @agent_module.ets_lookup(name, :k, 10, 50, :undefined)

      assert length(records) == 2

      assert Enum.all?(records, fn {:k, value} ->
               is_binary(value) and byte_size(value) < 10_000
             end)
    end

    test "raises badarg for a private table owned by another process" do
      pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
      tid = Agent.get(pid, & &1)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_lookup(tid, :k, 10, @budget, :undefined)
      end
    end

    test "raises badarg for a negative budget" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      assert_raise ArgumentError, fn ->
        @agent_module.ets_lookup(name, :k, 10, -1, :undefined)
      end
    end

    test "restores the caller's max_heap_size instead of leaving it capped" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      before = Process.info(self(), :max_heap_size)
      assert {:ok, _chunk} = @agent_module.ets_lookup(name, :k, 10, @budget, :undefined)
      assert Process.info(self(), :max_heap_size) == before
    end
  end

  describe "ets_select_spec/5" do
    test "does not require the gen_server to be registered" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      :ets.insert(name, {:k, 1})
      {:ok, spec} = Search.compile({:key_eq, :k})

      assert Process.whereis(@agent_module) == nil

      assert {:ok, %{records: [{:k, 1}], continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_spec(name, spec, 10, @budget, :undefined)
    end

    test "pages after an ETF-round-tripped continuation repaired against the caller spec" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      for i <- 1..25, do: :ets.insert(name, {i, :hit})
      {:ok, spec} = Search.compile({:element_eq, 2, :hit})

      assert {:ok, %{records: records, continuation: cont, truncated: false}} =
               @agent_module.ets_select_spec(name, spec, 10, @budget, :undefined)

      assert length(records) == 10
      assert Enum.all?(records, fn {_i, tag} -> tag == :hit end)

      broken = :erlang.binary_to_term(:erlang.term_to_binary(cont))
      :erlang.garbage_collect()

      assert {:ok, %{records: more, continuation: cont2, truncated: false}} =
               @agent_module.ets_select_spec(name, spec, 10, @budget, broken)

      assert length(more) == 10
      assert Enum.all?(more, fn {_i, tag} -> tag == :hit end)

      assert {:ok, %{records: last, continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_spec(name, spec, 10, @budget, cont2)

      assert length(last) == 5
    end

    test "raises badarg for a spec that is not a one-clause source MS" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_spec(name, "not a spec", 10, @budget, :undefined)
      end
    end

    test "raises badarg for a negative budget" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      {:ok, spec} = Search.compile({:key_eq, :k})

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_spec(name, spec, 10, -1, :undefined)
      end
    end
  end

  defp assert_paged_key_lookup(name) do
    for i <- 1..25, do: :ets.insert(name, {:k, i})

    assert {:ok, %{records: page, continuation: cont, truncated: false}} =
             @agent_module.ets_lookup(name, :k, 10, @budget, :undefined)

    assert length(page) == 10
    assert cont == {@skip, 10}

    broken = :erlang.binary_to_term(:erlang.term_to_binary(cont))
    :erlang.garbage_collect()

    assert {:ok, %{records: page2, continuation: cont2, truncated: false}} =
             @agent_module.ets_lookup(name, :k, 10, @budget, broken)

    assert length(page2) == 10
    assert cont2 == {@skip, 20}

    assert {:ok, %{records: page3, continuation: :undefined, truncated: false}} =
             @agent_module.ets_lookup(name, :k, 10, @budget, cont2)

    assert length(page3) == 5

    values = Enum.map(page ++ page2 ++ page3, fn {:k, i} -> i end)
    assert Enum.sort(values) == Enum.to_list(1..25)
  end

  defp mixed_arity_table(type) do
    name = EtsTable.unique_name()
    :ets.new(name, [:named_table, :public, type])
    :ets.insert(name, {:k, 1})
    :ets.insert(name, wide_record(:k, 256))
    name
  end

  defp assert_lookup_matches_ets(name, key) do
    expected = :ets.lookup(name, key)

    assert {:ok, %{records: ^expected, continuation: :undefined, truncated: false}} =
             @agent_module.ets_lookup(name, key, 10, @budget, :undefined)
  end

  defp wide_record(key, arity) when arity > 1 do
    :erlang.setelement(1, :erlang.make_tuple(arity, 0), key)
  end
end
