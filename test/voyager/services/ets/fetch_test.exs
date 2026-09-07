defmodule Voyager.Services.Ets.FetchTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Agent
  alias Voyager.Services.Ets.Fetch

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 3_000

  describe "select_chunk/5" do
    test "calls :voyager_agent.ets_select_chunk/3 with :undefined for a nil continuation" do
      test = self()
      table = :cached
      cont = make_ref()

      expect(Voyager.ErpcMock, :call, fn node, :voyager_agent, :ets_select_chunk, args, timeout ->
        send(test, {:called, node, args, timeout})
        {[{:ok, 1}], cont}
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, table, 10, nil, @timeout)
      assert chunk.records == [{:ok, 1}]
      assert chunk.continuation == cont
      refute Map.has_key?(chunk, :via)

      assert_received {:called, @node, [^table, 10, :undefined], @timeout}
    end

    test "passes a raw continuation through to the agent, not :undefined" do
      cont = {:ets_cont, 1}

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 20, ^cont],
                                         @timeout ->
        :"$end_of_table"
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 20, cont, @timeout)
      assert chunk.records == []
      assert chunk.continuation == nil
    end

    test "maps {records, :\"$end_of_table\"} to continuation nil" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 10, :undefined],
                                         @timeout ->
        {[{:a, 1}], :"$end_of_table"}
      end)

      assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
      assert chunk.records == [{:a, 1}]
      assert chunk.continuation == nil
    end

    test "does not retry a missing agent export as :ets.select" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, _args, _timeout ->
        send(test, {:called, mod, fun})
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Fetch.select_chunk(@node, :t, 10, nil, @timeout)

      assert_received {:called, :voyager_agent, :ets_select_chunk}
      refute_received {:called, :ets, _}
    end

    test "maps remote badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "does not map a wrapped agent worker badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, {:agent_worker_down, {:badarg, []}}, []})
      end)

      assert {:error, {:remote_exception, {:agent_worker_down, {:badarg, []}}}} =
               Fetch.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "returns :invalid_response when select does not return a chunk" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :oops
      end)

      assert {:error, :invalid_response} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "rejects a limit outside 10, 20, 50 without touching the remote" do
      assert Fetch.chunk_sizes() == [10, 20, 50]
      assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 15, nil, @timeout)
      assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 1, nil, @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Fetch.select_chunk(@node, self(), 10, nil, @timeout)
    end

    test "defaults the timeout to Agent.default_timeout/0" do
      timeout = Agent.default_timeout()

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 10, :undefined],
                                         ^timeout ->
        :"$end_of_table"
      end)

      assert {:ok, %{records: [], continuation: nil}} = Fetch.select_chunk(@node, :t, 10)
    end
  end

  describe "lookup/4" do
    test "calls :voyager_agent.ets_lookup/2 with the timeout" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, [:t, 7], @timeout ->
        [{7, :ok}]
      end)

      assert {:ok, chunk} = Fetch.lookup(@node, :t, 7, @timeout)
      assert chunk.records == [{7, :ok}]
      assert chunk.continuation == nil
      refute Map.has_key?(chunk, :via)
    end

    test "does not retry a missing agent export as :ets.lookup" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, _args, _timeout ->
        send(test, {:called, mod, fun})
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} = Fetch.lookup(@node, :t, :k, @timeout)
      assert_received {:called, :voyager_agent, :ets_lookup}
      refute_received {:called, :ets, _}
    end

    test "maps remote badarg to :cannot_read" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Fetch.lookup(@node, :t, <<"k">>, @timeout)
    end

    test "rejects a key that is not an atom, integer, or binary without touching the remote" do
      assert {:error, :invalid_key} = Fetch.lookup(@node, :t, {:tuple, 1}, @timeout)
      assert {:error, :invalid_key} = Fetch.lookup(@node, :t, self(), @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Fetch.lookup(@node, self(), :k, @timeout)
    end

    test "returns :invalid_response when lookup does not return a list" do
      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, _, _ ->
        :undefined
      end)

      assert {:error, :invalid_response} = Fetch.lookup(@node, :t, :k, @timeout)
    end
  end
end
