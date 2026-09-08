defmodule Voyager.Services.Ets.SearchTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Agent
  alias Voyager.Services.Ets.Search

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 3_000
  @budget Agent.default_budget()
  @max_prefix_bytes 512

  describe "compile/2" do
    test "key_eq compiles an element-equals spec and matches via :ets.test_ms/2" do
      assert {:ok, spec} = Search.compile({:key_eq, :k}, 1)
      assert {:ok, {:k, 1}} = :ets.test_ms({:k, 1}, spec)
      assert {:ok, false} = :ets.test_ms({:other, 1}, spec)
    end

    test "key_eq at keypos 2 matches the key field, not element 1" do
      assert {:ok, spec} = Search.compile({:key_eq, :k}, 2)
      assert {:ok, {1, :k}} = :ets.test_ms({1, :k}, spec)
      assert {:ok, false} = :ets.test_ms({:k, 1}, spec)
    end

    test "key_prefix matches a binary key prefix and skips non-binaries" do
      assert {:ok, spec} = Search.compile({:key_prefix, <<"ab">>}, 1)
      assert {:ok, {<<"abc">>, 1}} = :ets.test_ms({<<"abc">>, 1}, spec)
      assert {:ok, false} = :ets.test_ms({<<"xbc">>, 1}, spec)
      assert {:ok, false} = :ets.test_ms({:atom, 1}, spec)
      assert {:ok, false} = :ets.test_ms({<<"a">>, 1}, spec)
    end

    test "element_eq matches a non-key field" do
      assert {:ok, spec} = Search.compile({:element_eq, 2, :v})
      assert {:ok, {:k, :v}} = :ets.test_ms({:k, :v}, spec)
      assert {:ok, false} = :ets.test_ms({:k, :other}, spec)
    end

    test "key_eq treats :\"$1\" as a literal, not a match variable" do
      assert {:ok, spec} = Search.compile({:key_eq, :"$1"}, 1)
      assert {:ok, {:"$1", 1}} = :ets.test_ms({:"$1", 1}, spec)
      assert {:ok, false} = :ets.test_ms({:k, 1}, spec)
    end

    test "key_eq treats :\"$2\" as a literal, not an unbound match variable" do
      assert {:ok, spec} = Search.compile({:key_eq, :"$2"}, 1)
      assert {:ok, {:"$2", 1}} = :ets.test_ms({:"$2", 1}, spec)
      assert {:ok, false} = :ets.test_ms({:"$1", 1}, spec)
    end

    test "rejects a match-spec string" do
      assert {:error, :invalid_query} = Search.compile("fn x -> true end")
      assert {:error, :invalid_query} = Search.compile("[{:'$1', [], [:'$1']}]")
    end

    test "rejects a tuple as a key or field value" do
      assert {:error, :invalid_query} = Search.compile({:key_eq, {:tuple, 1}})
      assert {:error, :invalid_query} = Search.compile({:element_eq, 1, %{a: 1}})
    end

    test "rejects an empty or oversized key prefix" do
      assert {:error, :invalid_query} = Search.compile({:key_prefix, <<>>})

      oversized = :binary.copy(<<"a">>, @max_prefix_bytes + 1)
      assert {:error, :invalid_query} = Search.compile({:key_prefix, oversized})
    end

    test "rejects a non-positive element index" do
      assert {:error, :invalid_query} = Search.compile({:element_eq, 0, :v})
      assert {:error, :invalid_query} = Search.compile({:element_eq, -1, :v})
    end
  end

  describe "chunk/7" do
    test "rejects an invalid query without a remote call" do
      assert {:error, :invalid_query} =
               Search.chunk(@node, :t, "[{:'$1', [], [:'$1']}]", 10, @budget, nil, @timeout)

      assert {:error, :invalid_query} =
               Search.chunk(@node, :t, {:key_eq, {1, 2}}, 10, @budget, nil, @timeout)

      assert {:error, :invalid_query} =
               Search.chunk(@node, :t, {:key_prefix, <<>>}, 10, @budget, nil, @timeout)
    end

    test "rejects a handle that is not an atom or reference without a remote call" do
      assert {:error, :invalid_table} =
               Search.chunk(@node, self(), {:key_eq, :k}, 10, @budget, nil, @timeout)
    end

    test "rejects a negative budget without a remote call" do
      assert {:error, :invalid_budget} =
               Search.chunk(@node, :t, {:key_eq, :k}, 10, -1, nil, @timeout)
    end

    test "rejects a limit outside Fetch.chunk_sizes/0 without a remote call" do
      assert {:error, :invalid_limit} =
               Search.chunk(@node, :t, {:key_eq, :k}, 15, @budget, nil, @timeout)

      assert {:error, :invalid_limit} =
               Search.chunk(@node, :t, {:element_eq, 2, :v}, 15, @budget, nil, @timeout)
    end

    test "key_eq looks up through the agent without fetching table info" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_lookup,
                                         [:t, :the_key, 10, @budget, :undefined],
                                         @timeout ->
        ok_chunk([{1, :the_key}])
      end)

      assert {:ok, chunk} =
               Search.chunk(@node, :t, {:key_eq, :the_key}, 10, @budget, nil, @timeout)

      assert chunk.records == [{1, :the_key}]
      refute Map.has_key?(chunk, :via)
      assert chunk.continuation == nil
      refute chunk.truncated?
    end

    test "key_eq passes a raw continuation through to the agent" do
      cont = make_ref()

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_lookup,
                                         [:t, :k, 10, @budget, ^cont],
                                         @timeout ->
        ok_chunk([], :undefined)
      end)

      assert {:ok, chunk} =
               Search.chunk(@node, :t, {:key_eq, :k}, 10, @budget, cont, @timeout)

      assert chunk.records == []
      assert chunk.continuation == nil
      refute chunk.truncated?
    end

    test "key_prefix compiles using table keypos" do
      stub_info(1)

      spec =
        [
          {:"$1",
           [
             {:is_binary, {:element, 1, :"$1"}},
             {:>=, {:byte_size, {:element, 1, :"$1"}}, 3},
             {:"=:=", {:binary_part, {:element, 1, :"$1"}, 0, 3}, <<"alp">>}
           ], [:"$1"]}
        ]

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_spec,
                                         [:t, ^spec, 10, @budget, :undefined],
                                         @timeout ->
        ok_chunk([{<<"alpha">>, 1}])
      end)

      assert {:ok, chunk} =
               Search.chunk(@node, :t, {:key_prefix, <<"alp">>}, 10, @budget, nil, @timeout)

      assert chunk.records == [{<<"alpha">>, 1}]
      refute Map.has_key?(chunk, :via)
      refute chunk.truncated?
    end

    test "element_eq does not fetch table info" do
      spec = [{:"$1", [{:"=:=", {:element, 2, :"$1"}, {:const, :v}}], [:"$1"]}]

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_spec,
                                         [:t, ^spec, 10, @budget, :undefined],
                                         @timeout ->
        ok_chunk([{:a, :v}])
      end)

      assert {:ok, chunk} =
               Search.chunk(@node, :t, {:element_eq, 2, :v}, 10, @budget, nil, @timeout)

      assert chunk.records == [{:a, :v}]
    end

    test "passes a raw continuation through to the agent" do
      spec = [{:"$1", [{:"=:=", {:element, 1, :"$1"}, {:const, :k}}], [:"$1"]}]
      cont = make_ref()

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_spec,
                                         [:t, ^spec, 10, @budget, ^cont],
                                         @timeout ->
        ok_chunk([], :undefined)
      end)

      assert {:ok, chunk} =
               Search.chunk(@node, :t, {:element_eq, 1, :k}, 10, @budget, cont, @timeout)

      assert chunk.records == []
      assert chunk.continuation == nil
      refute chunk.truncated?
    end

    test "maps a missing table on key prefix to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [:t, :keypos], @timeout ->
        :undefined
      end)

      assert {:error, :cannot_read} =
               Search.chunk(@node, :t, {:key_prefix, <<"ab">>}, 10, @budget, nil, @timeout)
    end

    test "does not retry a missing agent export as :ets.select" do
      test = self()
      spec = [{:"$1", [{:"=:=", {:element, 2, :"$1"}, {:const, :v}}], [:"$1"]}]

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
        send(test, {:called, mod, fun, args})
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Search.chunk(@node, :t, {:element_eq, 2, :v}, 10, @budget, nil, @timeout)

      assert_received {:called, :voyager_agent, :ets_select_spec,
                       [:t, ^spec, 10, @budget, :undefined]}

      refute_received {:called, :ets, _}
    end
  end

  defp ok_chunk(records, continuation \\ :undefined, truncated \\ false) do
    {:ok, %{records: records, continuation: continuation, truncated: truncated}}
  end

  defp stub_info(keypos) do
    expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [:t, :keypos], @timeout ->
      keypos
    end)
  end
end
