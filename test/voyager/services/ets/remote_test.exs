defmodule Voyager.Services.Ets.RemoteTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Remote

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 3_000

  describe "list/2" do
    test "fetches :ets.all/0, target wordsize, and maps :ets.info/1 with the timeout" do
      test = self()
      named = :voyager_ets_named
      unnamed = make_ref()

      expect(Voyager.ErpcMock, :call, fn node, :ets, :all, [], timeout ->
        send(test, {:called, :all, node, timeout})
        [named, unnamed]
      end)

      expect(Voyager.ErpcMock, :call, fn node, :erlang, :system_info, [:wordsize], timeout ->
        send(test, {:called, :wordsize, node, timeout})
        8
      end)

      expect(Voyager.ErpcMock, :call, fn node, :lists, :map, [fun, ids], timeout ->
        send(test, {:called, :map, node, ids, timeout, Function.info(fun)})
        [info_kw(name: named, named_table: true, memory: 10), info_kw(name: :unnamed, memory: 3)]
      end)

      assert {:ok, [named_info, unnamed_info]} = Remote.list(@node, @timeout)

      assert_received {:called, :all, @node, @timeout}
      assert_received {:called, :wordsize, @node, @timeout}

      assert_received {:called, :map, @node, [^named, ^unnamed], @timeout, fun_info}
      assert fun_info[:type] == :external
      assert fun_info[:module] == :ets
      assert fun_info[:name] == :info
      assert fun_info[:arity] == 1

      assert named_info.id == named
      assert named_info.memory == 80
      assert unnamed_info.id == unnamed
      assert unnamed_info.memory == 24
    end

    test "drops tables that die mid-fetch (:undefined) and keeps private tables" do
      gone = make_ref()
      private = make_ref()

      stub_list([gone, private], 8, [
        :undefined,
        info_kw(name: :priv, protection: :private, memory: 2)
      ])

      assert {:ok, [table]} = Remote.list(@node, @timeout)
      assert table.id == private
      assert table.protection == :private
      assert table.memory == 16
    end

    test "drops a row whose memory is not a non-negative integer" do
      stub_list([:bad, :ok], 8, [info_kw(memory: :oops), info_kw(name: :ok, memory: 1)])

      assert {:ok, [table]} = Remote.list(@node, @timeout)
      assert table.id == :ok
      assert table.memory == 8
    end

    test "drops a row missing required info keys" do
      incomplete = Keyword.delete(info_kw(name: :bad), :protection)
      stub_list([:bad, :ok], 8, [incomplete, info_kw(name: :ok, memory: 1)])

      assert {:ok, [table]} = Remote.list(@node, @timeout)
      assert table.id == :ok
    end

    test "drops a row whose info list is not a keyword list" do
      stub_list([:bad, :ok], 8, [[:foo], info_kw(name: :ok, memory: 1)])

      assert {:ok, [table]} = Remote.list(@node, @timeout)
      assert table.id == :ok
    end

    test "returns :invalid_response when info rows are not aligned with :ets.all/0" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], @timeout -> [:a, :b] end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :lists, :map, [_fun, [:a, :b]], @timeout ->
        [info_kw([])]
      end)

      assert {:error, :invalid_response} = Remote.list(@node, @timeout)
    end

    test "skips wordsize and info when :ets.all/0 is empty" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], @timeout -> [] end)

      assert {:ok, []} = Remote.list(@node, @timeout)
    end

    test "defaults the timeout to Erpc.default_timeout/0" do
      timeout = Erpc.default_timeout()
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], ^timeout -> [] end)

      assert {:ok, []} = Remote.list(@node)
    end

    test "does not call :voyager_agent" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn _node, mod, _fun, _args, _timeout ->
        send(test, {:called_mod, mod})
        []
      end)

      assert {:ok, []} = Remote.list(@node, @timeout)
      assert_received {:called_mod, mod}
      refute mod == :voyager_agent
    end

    test "propagates :noconnection from the first erpc call" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Remote.list(@node, @timeout)
    end

    test "propagates :timeout from the info map call" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], @timeout -> [:t] end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :lists, :map, [_fun, [:t]], @timeout ->
        :erlang.error({:erpc, :timeout})
      end)

      assert {:error, :timeout} = Remote.list(@node, @timeout)
    end

    test "returns :invalid_response when wordsize is not a positive integer" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], @timeout -> [:t] end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        0
      end)

      assert {:error, :invalid_response} = Remote.list(@node, @timeout)
    end

    test "passes through decentralized_counters when present" do
      stub_list([:t], 8, [info_kw(decentralized_counters: true)])

      assert {:ok, [table]} = Remote.list(@node, @timeout)
      assert table.decentralized_counters == true
    end
  end

  describe "info/3" do
    test "fetches :ets.info/1 and converts memory with the target wordsize" do
      table = :my_table

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [^table], @timeout ->
        info_kw(name: table, named_table: true, memory: 5, size: 12)
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      assert {:ok, info} = Remote.info(@node, table, @timeout)
      assert info.id == table
      assert info.size == 12
      assert info.memory == 40
      assert info.named_table
    end

    test "returns :not_found when the table is gone, without fetching wordsize" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [_table], @timeout -> :undefined end)

      assert {:error, :not_found} = Remote.info(@node, make_ref(), @timeout)
    end

    test "returns :invalid_response when memory cannot be converted to bytes" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [:t], @timeout ->
        info_kw(memory: :oops)
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      assert {:error, :invalid_response} = Remote.info(@node, :t, @timeout)
    end

    test "returns :invalid_response when required info keys are missing" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [:t], @timeout ->
        Keyword.delete(info_kw([]), :owner)
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      assert {:error, :invalid_response} = Remote.info(@node, :t, @timeout)
    end

    test "returns :invalid_response when the info list is not a keyword list" do
      expect(Voyager.ErpcMock, :call, fn @node, :ets, :info, [:t], @timeout -> [:foo] end)

      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
        8
      end)

      assert {:error, :invalid_response} = Remote.info(@node, :t, @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Remote.info(@node, self(), @timeout)
    end

    test "propagates remote exceptions" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, {:remote_exception, :badarg}} = Remote.info(@node, :t, @timeout)
    end
  end

  defp stub_list(ids, word_size, infos) do
    expect(Voyager.ErpcMock, :call, fn @node, :ets, :all, [], @timeout -> ids end)

    expect(Voyager.ErpcMock, :call, fn @node, :erlang, :system_info, [:wordsize], @timeout ->
      word_size
    end)

    expect(Voyager.ErpcMock, :call, fn @node, :lists, :map, [_fun, ^ids], @timeout -> infos end)
  end

  defp info_kw(overrides) do
    [
      id: make_ref(),
      name: :test_table,
      named_table: false,
      protection: :public,
      type: :set,
      size: 0,
      memory: 1,
      owner: self(),
      heir: :none,
      keypos: 1,
      compressed: false,
      read_concurrency: false,
      write_concurrency: false
    ]
    |> Keyword.merge(overrides)
  end

  describe "select_chunk/5" do
    test "probes ets_select_chunk/3 then match-all :ets.select/3 with the timeout" do
      test = self()
      table = :voyager_chunk
      cont = make_ref()

      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn node, :ets, :select, [^table, spec, 10], timeout ->
        send(test, {:called, :select, node, spec, timeout})
        {[{:a, 1}], cont}
      end)

      assert {:ok, chunk} = Remote.select_chunk(@node, table, 10, nil, @timeout)
      assert chunk.records == [{:a, 1}]
      assert chunk.continuation == cont
      assert chunk.via == :mfa

      assert_received {:called, :select, @node, [{:"$1", [], [:"$1"]}], @timeout}
    end

    test "uses :ets.select/1 for a continuation page" do
      cont = make_ref()
      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [^cont], @timeout ->
        :"$end_of_table"
      end)

      assert {:ok, chunk} = Remote.select_chunk(@node, :t, 10, cont, @timeout)
      assert chunk.records == []
      assert chunk.continuation == nil
      assert chunk.via == :mfa
    end

    test "calls :voyager_agent.ets_select_chunk/3 when the export is present" do
      test = self()
      table = :cached
      cont = make_ref()

      stub_exported(:ets_select_chunk, 3, true)

      expect(Voyager.ErpcMock, :call, fn node, :voyager_agent, :ets_select_chunk, args, timeout ->
        send(test, {:called, node, args, timeout})
        {[{:ok, 1}], cont}
      end)

      assert {:ok, chunk} = Remote.select_chunk(@node, table, 10, nil, @timeout)
      assert chunk.via == :agent
      assert chunk.records == [{:ok, 1}]
      assert chunk.continuation == cont

      assert_received {:called, @node, [^table, 10, :undefined], @timeout}
    end

    test "passes a raw continuation through to the agent, not :undefined" do
      cont = {:ets_cont, 1}
      stub_exported(:ets_select_chunk, 3, true)

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :voyager_agent,
                                         :ets_select_chunk,
                                         [:t, 20, ^cont],
                                         @timeout ->
        :"$end_of_table"
      end)

      assert {:ok, chunk} = Remote.select_chunk(@node, :t, 20, cont, @timeout)
      assert chunk.via == :agent
      assert chunk.continuation == nil
    end

    test "does not call :voyager_agent when exports are missing" do
      test = self()
      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn _node, mod, fun, _args, _timeout ->
        send(test, {:called, mod, fun})
        :"$end_of_table"
      end)

      assert {:ok, %{via: :mfa}} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
      assert_received {:called, :ets, :select}
      refute_received {:called, :voyager_agent, _}
    end

    test "does not fall back to MFA when the agent is undef after a successful probe" do
      stub_exported(:ets_select_chunk, 3, true)

      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "does not fall back to MFA when the probe returns :noconnection" do
      expect(Voyager.ErpcMock, :call, fn _, :erlang, :function_exported, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "does not fall back to MFA when :ets.select times out" do
      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, _, _ ->
        :erlang.error({:erpc, :timeout})
      end)

      assert {:error, :timeout} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "maps remote badarg to :cannot_read without MFA fallback" do
      stub_exported(:ets_select_chunk, 3, true)

      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "maps MFA badarg to :cannot_read" do
      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "returns :invalid_response when select does not return a chunk" do
      stub_exported(:ets_select_chunk, 3, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, _, _ -> :oops end)

      assert {:error, :invalid_response} = Remote.select_chunk(@node, :t, 10, nil, @timeout)
    end

    test "rejects a limit outside 10, 20, 50 without touching the remote" do
      assert {:error, :invalid_limit} = Remote.select_chunk(@node, :t, 15, nil, @timeout)
      assert {:error, :invalid_limit} = Remote.select_chunk(@node, :t, 1, nil, @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Remote.select_chunk(@node, self(), 10, nil, @timeout)
    end

    test "defaults the timeout to 5_000 ms" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :erlang,
                                         :function_exported,
                                         [:voyager_agent, :ets_select_chunk, 3],
                                         5_000 ->
        false
      end)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, _spec, 10], 5_000 ->
        :"$end_of_table"
      end)

      assert {:ok, %{via: :mfa}} = Remote.select_chunk(@node, :t, 10)
    end
  end

  describe "lookup/4" do
    test "probes ets_lookup/2 then :ets.lookup/2 with the timeout" do
      test = self()
      stub_exported(:ets_lookup, 2, false)

      expect(Voyager.ErpcMock, :call, fn node, :ets, :lookup, [:t, :k], timeout ->
        send(test, {:called, node, timeout})
        [{:t, :k, 1}]
      end)

      assert {:ok, chunk} = Remote.lookup(@node, :t, :k, @timeout)
      assert chunk.records == [{:t, :k, 1}]
      assert chunk.continuation == nil
      assert chunk.via == :mfa
      assert_received {:called, @node, @timeout}
    end

    test "calls :voyager_agent.ets_lookup/2 when the export is present" do
      stub_exported(:ets_lookup, 2, true)

      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, [:t, 7], @timeout ->
        [{7, :ok}]
      end)

      assert {:ok, chunk} = Remote.lookup(@node, :t, 7, @timeout)
      assert chunk.via == :agent
      assert chunk.records == [{7, :ok}]
    end

    test "does not fall back to MFA when the agent is undef after a successful probe" do
      stub_exported(:ets_lookup, 2, true)

      expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_lookup, _, _ ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} = Remote.lookup(@node, :t, :k, @timeout)
    end

    test "maps remote badarg to :cannot_read" do
      stub_exported(:ets_lookup, 2, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :lookup, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :cannot_read} = Remote.lookup(@node, :t, <<"k">>, @timeout)
    end

    test "rejects a key that is not an atom, integer, or binary without touching the remote" do
      assert {:error, :invalid_key} = Remote.lookup(@node, :t, {:tuple, 1}, @timeout)
      assert {:error, :invalid_key} = Remote.lookup(@node, :t, self(), @timeout)
    end

    test "rejects a handle that is not an atom or reference without touching the remote" do
      assert {:error, :invalid_table} = Remote.lookup(@node, self(), :k, @timeout)
    end

    test "returns :invalid_response when lookup does not return a list" do
      stub_exported(:ets_lookup, 2, false)

      expect(Voyager.ErpcMock, :call, fn @node, :ets, :lookup, _, _ -> :undefined end)

      assert {:error, :invalid_response} = Remote.lookup(@node, :t, :k, @timeout)
    end
  end

  defp stub_exported(fun, arity, exported?) do
    expect(Voyager.ErpcMock, :call, fn @node,
                                       :erlang,
                                       :function_exported,
                                       [:voyager_agent, ^fun, ^arity],
                                       @timeout ->
      exported?
    end)
  end
end
