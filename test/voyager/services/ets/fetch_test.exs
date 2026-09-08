defmodule Voyager.Services.Ets.FetchTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Agent
  alias Voyager.Services.Ets.Fetch

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 3_000
  @budget Agent.default_budget()

  describe "select_chunk/6" do
    test "calls :voyager_agent.ets_select_chunk/4 with the budget and :undefined for a nil continuation" do
      test = self()
      table = :cached
      cont = make_ref()

      expect(Voyager.ErpcMock, :call, fn node, :voyager_agent, :ets_select_chunk, args, timeout ->
        send(test, {:called, node, args, timeout})
        ok_chunk([{:ok, 1}], cont)
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, table, 10, @budget, nil, @timeout)
      assert chunk.records == [{:ok, 1}]
      assert chunk.continuation == cont
      refute chunk.truncated?
      refute Map.has_key?(chunk, :via)

      assert_received {:called, @node, [^table, 10, @budget, :undefined], @timeout}
    end

    test "passes a raw continuation through to the agent, not :undefined" do
      cont = {:ets_cont, 1}

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 20, @budget, ^cont],
                                         @timeout ->
        ok_chunk([], :undefined)
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 20, @budget, cont, @timeout)
      assert chunk.records == []
      assert chunk.continuation == nil
      refute chunk.truncated?
    end

    test "maps continuation :undefined and :\"$end_of_table\" to nil" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 10, @budget, :undefined],
                                         @timeout ->
        ok_chunk([{:a, 1}], :"$end_of_table")
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
      assert chunk.records == [{:a, 1}]
      assert chunk.continuation == nil
    end

    test "renames the agent's truncated flag to truncated?" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        ok_chunk([{:k, :"$voyager_truncated"}], :undefined, true)
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 10, 50, nil, @timeout)
      assert chunk.truncated?
      assert chunk.records == [{:k, :"$voyager_truncated"}]
    end

    test "does not retry a missing agent export as :ets.select" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, _args, _timeout ->
        send(test, {:called, mod, fun})
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)

      assert_received {:called, :voyager_agent, :ets_select_chunk}
      refute_received {:called, :ets, _}
    end

    test "maps remote badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
    end

    test "does not map a wrapped agent worker badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, {:agent_worker_down, {:badarg, []}}, []})
      end)

      assert {:error, {:remote_exception, {:agent_worker_down, {:badarg, []}}}} =
               Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
    end

    test "maps a remote worker heap kill to :heap_limit_exceeded" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, :killed, []})
      end)

      assert {:error, :heap_limit_exceeded} =
               Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
    end

    test "does not map a wrapped agent worker death to :heap_limit_exceeded" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, {:agent_worker_down, :killed}, []})
      end)

      assert {:error, {:remote_exception, {:agent_worker_down, :killed}}} =
               Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
    end

    test "returns :invalid_response when select does not return a chunk" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        {:ok, %{truncated: false}}
      end)

      assert {:error, :invalid_response} =
               Fetch.select_chunk(@node, :t, 10, @budget, nil, @timeout)
    end

    test "rejects a limit outside 1, 2, 5 10, 20, 50 without touching the remote" do
      assert Fetch.chunk_sizes() == [1, 2, 5, 10, 20, 50]
      assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 15, @budget, nil, @timeout)
      assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 3, @budget, nil, @timeout)
    end

    test "rejects a negative or non-integer budget without touching the remote" do
      assert {:error, :invalid_budget} = Fetch.select_chunk(@node, :t, 10, -1, nil, @timeout)
      assert {:error, :invalid_budget} = Fetch.select_chunk(@node, :t, 10, :nope, nil, @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} =
               Fetch.select_chunk(@node, self(), 10, @budget, nil, @timeout)
    end

    test "defaults the budget and timeout" do
      timeout = Agent.default_timeout()

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 10, @budget, :undefined],
                                         ^timeout ->
        ok_chunk([])
      end)

      assert {:ok, %{records: [], continuation: nil, truncated?: false}} =
               Fetch.select_chunk(@node, :t, 10)
    end
  end

  describe "lookup/5" do
    test "calls :voyager_agent.ets_lookup/3 with the budget and timeout" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_lookup,
                                         [:t, 7, @budget],
                                         @timeout ->
        ok_chunk([{7, :ok}])
      end)

      assert {:ok, chunk} = Fetch.lookup(@node, :t, 7, @budget, @timeout)
      assert chunk.records == [{7, :ok}]
      assert chunk.continuation == nil
      refute chunk.truncated?
      refute Map.has_key?(chunk, :via)
    end

    test "does not retry a missing agent export as :ets.lookup" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, _args, _timeout ->
        send(test, {:called, mod, fun})
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Fetch.lookup(@node, :t, :k, @budget, @timeout)

      assert_received {:called, :voyager_agent, :ets_lookup}
      refute_received {:called, :ets, _}
    end

    test "maps remote badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Fetch.lookup(@node, :t, <<"k">>, @budget, @timeout)
    end

    test "rejects a key that is not an atom, integer, or binary without touching the remote" do
      assert {:error, :invalid_key} = Fetch.lookup(@node, :t, {:tuple, 1}, @budget, @timeout)
      assert {:error, :invalid_key} = Fetch.lookup(@node, :t, self(), @budget, @timeout)
    end

    test "rejects a negative budget without touching the remote" do
      assert {:error, :invalid_budget} = Fetch.lookup(@node, :t, :k, -1, @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Fetch.lookup(@node, self(), :k, @budget, @timeout)
    end

    test "returns :invalid_response when lookup does not return a chunk" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, _, _ ->
        {:ok, %{truncated: false}}
      end)

      assert {:error, :invalid_response} = Fetch.lookup(@node, :t, :k, @budget, @timeout)
    end
  end

  defp ok_chunk(records, continuation \\ :undefined, truncated \\ false) do
    {:ok, %{records: records, continuation: continuation, truncated: truncated}}
  end
end
