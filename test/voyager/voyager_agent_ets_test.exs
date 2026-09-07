defmodule VoyagerAgentEtsTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Services.Ets.Search
  alias Voyager.Test.EtsTable
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module :voyager_agent
  @marker :"$voyager_truncated"
  @budget Voyager.Agent.default_budget()

  setup do
    VoyagerAgentFixture.load!()
    :ok
  end

  describe "ets_select_chunk/4 and ets_lookup/3" do
    test "do not require the gen_server to be registered" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)
      :ets.insert(name, {:k, 1})

      assert Process.whereis(@agent_module) == nil

      assert {:ok, %{records: [{:k, 1}], truncated: false}} =
               @agent_module.ets_lookup(name, :k, @budget)
    end

    test "walks each record with the budget and leaves the ETS continuation opaque" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

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
      on_exit(fn -> EtsTable.safe_delete(name) end)

      for i <- 1..10, do: :ets.insert(name, {i, i})

      assert {:ok, %{records: records, truncated: true}} =
               @agent_module.ets_select_chunk(name, 10, 0, :undefined)

      assert length(records) == 10
      assert Enum.all?(records, &(&1 == @marker))
    end

    test "pages through a table larger than the chunk size" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

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
      on_exit(fn -> EtsTable.safe_delete(name) end)

      for i <- 1..3, do: :ets.insert(name, {i, i})

      assert {:ok, %{records: records, continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, :undefined)

      assert length(records) == 3
    end

    test "returns an empty chunk for an empty table" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      assert {:ok, %{records: [], continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_chunk(name, 10, @budget, :undefined)
    end

    test "lookup truncates a matching record and keeps bag rows" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :duplicate_bag])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      blob = :binary.copy(<<"a">>, 10_000)
      :ets.insert(name, {:k, blob})
      :ets.insert(name, {:k, blob})

      assert {:ok, %{records: records, continuation: :undefined, truncated: true}} =
               @agent_module.ets_lookup(name, :k, 50)

      assert length(records) == 2

      assert Enum.all?(records, fn {:k, value} ->
               is_binary(value) and byte_size(value) < 10_000
             end)
    end

    test "raises badarg for a private table owned by another process" do
      pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
      tid = Agent.get(pid, & &1)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_chunk(tid, 10, @budget, :undefined)
      end

      assert_raise ArgumentError, fn -> @agent_module.ets_lookup(tid, :k, @budget) end
    end

    test "raises badarg for a negative budget" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_chunk(name, 10, -1, :undefined)
      end

      assert_raise ArgumentError, fn -> @agent_module.ets_lookup(name, :k, -1) end
    end

    @tag capture_log: true
    test "raises killed when the worker exceeds the target heap cap" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      :ets.insert(name, {:wide, Enum.to_list(1..400_000)})

      assert %ErlangError{original: :killed} =
               assert_raise(ErlangError, fn ->
                 @agent_module.ets_lookup(name, :wide, @budget)
               end)
    end
  end

  describe "ets_select_spec/5" do
    test "does not require the gen_server to be registered" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)
      :ets.insert(name, {:k, 1})
      {:ok, spec} = Search.compile({:key_eq, :k})

      assert Process.whereis(@agent_module) == nil

      assert {:ok, %{records: [{:k, 1}], continuation: :undefined, truncated: false}} =
               @agent_module.ets_select_spec(name, spec, 10, @budget, :undefined)
    end

    test "pages after an ETF-round-tripped continuation repaired against the caller spec" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

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
      on_exit(fn -> EtsTable.safe_delete(name) end)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_spec(name, "not a spec", 10, @budget, :undefined)
      end
    end

    test "raises badarg for a negative budget" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)
      {:ok, spec} = Search.compile({:key_eq, :k})

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_spec(name, spec, 10, -1, :undefined)
      end
    end
  end
end
