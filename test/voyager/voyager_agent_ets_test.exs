defmodule VoyagerAgentEtsTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Test.EtsSanitizeFixture
  alias Voyager.Test.EtsTable
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module :voyager_agent
  @marker :"$voyager_truncated"
  @binary_limit 512

  setup do
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

      assert {@marker, :binary, prefix, 4096} = @agent_module.truncate_term(huge)
      assert byte_size(prefix) == @binary_limit
      assert :binary.referenced_byte_size(prefix) == @binary_limit
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
    end

    test "truncates records and leaves the ETS continuation opaque" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      blob = :binary.copy(<<"a">>, 600)
      truncated = @agent_module.truncate_term(blob)

      for i <- 1..25, do: :ets.insert(name, {i, blob})

      assert {records, cont} = @agent_module.ets_select_chunk(name, 10, :undefined)
      assert length(records) == 10
      assert Enum.all?(records, fn {_i, value} -> value == truncated end)
      refute match?({:"$voyager_truncated", _, _, _}, cont)

      assert {more, cont2} = @agent_module.ets_select_chunk(name, 10, cont)
      assert length(more) == 10
      assert Enum.all?(more, fn {_i, value} -> value == truncated end)
      refute match?({:"$voyager_truncated", _, _, _}, cont2)

      assert {last, :"$end_of_table"} = @agent_module.ets_select_chunk(name, 10, cont2)
      assert length(last) == 5
      assert Enum.all?(last, fn {_i, value} -> value == truncated end)
    end

    test "pages through a table larger than the chunk size" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      for i <- 1..25, do: :ets.insert(name, {i, i})

      assert {page, cont} = @agent_module.ets_select_chunk(name, 10, :undefined)
      assert length(page) == 10
      assert cont != :"$end_of_table"

      assert {page2, cont2} = @agent_module.ets_select_chunk(name, 10, cont)
      assert length(page2) == 10
      assert cont2 != :"$end_of_table"

      assert {page3, :"$end_of_table"} = @agent_module.ets_select_chunk(name, 10, cont2)
      assert length(page3) == 5
    end

    test "maps a table smaller than the chunk size to '$end_of_table'" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      for i <- 1..3, do: :ets.insert(name, {i, i})

      assert {records, :"$end_of_table"} = @agent_module.ets_select_chunk(name, 10, :undefined)
      assert length(records) == 3
    end

    test "returns '$end_of_table' for an empty table" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      assert :"$end_of_table" = @agent_module.ets_select_chunk(name, 10, :undefined)
    end

    test "lookup truncates a matching record" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      :ets.insert(name, {:k, Enum.to_list(1..60)})

      assert [{:k, truncated}] = @agent_module.ets_lookup(name, :k)
      assert truncated == @agent_module.truncate_term(Enum.to_list(1..60))
    end

    test "raises badarg for a private table owned by another process" do
      pid = start_supervised!({Agent, fn -> :ets.new(EtsTable.unique_name(), [:private]) end})
      tid = Agent.get(pid, & &1)

      assert_raise ArgumentError, fn ->
        @agent_module.ets_select_chunk(tid, 10, :undefined)
      end

      assert_raise ArgumentError, fn -> @agent_module.ets_lookup(tid, :k) end
    end

    @tag capture_log: true
    test "raises killed when the worker exceeds the target heap cap" do
      name = EtsTable.unique_name()
      :ets.new(name, [:named_table, :public, :set])
      on_exit(fn -> EtsTable.safe_delete(name) end)

      :ets.insert(name, {:wide, Enum.to_list(1..400_000)})

      assert %ErlangError{original: :killed} =
               assert_raise(ErlangError, fn -> @agent_module.ets_lookup(name, :wide) end)
    end
  end
end
