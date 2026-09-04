defmodule Voyager.Services.Ets.FetchTest do
  # async: false because isolate/2 runs Erpc in a TaskSupervisor child; Mox must be global.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Sanitize

  setup :set_mox_global
  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 3_000

  test "propagates :invalid_limit without a remote call" do
    assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 15, nil, @timeout)
  end

  test "propagates :invalid_table without a remote call" do
    assert {:error, :invalid_table} = Fetch.select_chunk(@node, self(), 10, nil, @timeout)
  end

  test "propagates :invalid_spec without a remote call" do
    assert {:error, :invalid_spec} =
             Fetch.select_spec(@node, :t, "fn x -> true end", 10, nil, @timeout)
  end

  test "propagates :invalid_key without a remote call" do
    assert {:error, :invalid_key} = Fetch.lookup(@node, :t, {:tuple, 1}, @timeout)
  end

  test "sanitizes records from a remote chunk" do
    blob = :binary.copy(<<"z">>, 600)
    stub_exported(:ets_lookup, 2, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :lookup, [:t, :k], @timeout ->
      [{:row, blob}]
    end)

    assert {:ok, chunk} = Fetch.lookup(@node, :t, :k, @timeout)
    assert chunk.records == [{:row, Sanitize.term(blob)}]
  end

  test "does not sanitize the ETS continuation" do
    cont = :binary.copy(<<"c">>, 600)
    stub_exported(:ets_select_chunk, 3, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, _spec, 10], @timeout ->
      {[{:k, :v}], cont}
    end)

    assert {:ok, chunk} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
    assert chunk.records == [{:k, :v}]
    assert chunk.continuation == cont
  end

  test "select_spec/6 sanitizes records and does not sanitize the continuation" do
    blob = :binary.copy(<<"z">>, 600)
    cont = :binary.copy(<<"c">>, 600)
    spec = [{:"$1", [{:"=:=", {:element, 1, :"$1"}, :k}], [:"$1"]}]
    stub_exported(:ets_select_spec, 4, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, ^spec, 10], @timeout ->
      {[{:k, blob}], cont}
    end)

    assert {:ok, chunk} = Fetch.select_spec(@node, :t, spec, 10, nil, @timeout)
    assert chunk.records == [{:k, Sanitize.term(blob)}]
    assert chunk.continuation == cont
  end

  @tag capture_log: true
  test "returns :heap_limit_exceeded when the copied payload exceeds the host heap cap" do
    stub_exported(:ets_lookup, 2, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :lookup, [:t, :wide], 15_000 ->
      [{:wide, Enum.to_list(1..400_000)}]
    end)

    assert {:error, :heap_limit_exceeded} = Fetch.lookup(@node, :t, :wide, 15_000)
  end

  test "returns :timeout when the isolated task does not finish in time" do
    stub_exported(:ets_select_chunk, 3, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, _spec, 10], 50 ->
      receive do
      after
        :infinity -> :"$end_of_table"
      end
    end)

    assert {:error, :timeout} = Fetch.select_chunk(@node, :t, 10, nil, 50)
  end

  test "yields long enough for a probe and a read that each use the full timeout" do
    timeout = 80

    expect(Voyager.ErpcMock, :call, fn @node,
                                       :erlang,
                                       :function_exported,
                                       [:voyager_agent, :ets_select_chunk, 3],
                                       ^timeout ->
      Process.sleep(timeout)
      false
    end)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, _spec, 10], ^timeout ->
      Process.sleep(timeout)
      :"$end_of_table"
    end)

    assert {:ok, %{records: [], continuation: nil}} =
             Fetch.select_chunk(@node, :t, 10, nil, timeout)
  end

  test "returns {:task_exit, reason} when the isolated task exits for another reason" do
    stub_exported(:ets_select_chunk, 3, false)

    expect(Voyager.ErpcMock, :call, fn @node, :ets, :select, [:t, _spec, 10], @timeout ->
      Process.exit(self(), :shutdown)
    end)

    assert {:error, {:task_exit, :shutdown}} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
  end

  test "maps a remote worker kill to :heap_limit_exceeded without MFA fallback" do
    stub_exported(:ets_lookup, 2, true)

    expect(Voyager.ErpcMock, :call, fn @node,
                                       :voyager_agent,
                                       :ets_lookup,
                                       [:t, :wide],
                                       @timeout ->
      :erlang.error({:exception, :killed, []})
    end)

    assert {:error, :heap_limit_exceeded} = Fetch.lookup(@node, :t, :wide, @timeout)
  end

  test "maps an erpc-wrapped remote exit(:killed) to :heap_limit_exceeded without MFA fallback" do
    stub_exported(:ets_select_chunk, 3, true)

    expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, @timeout ->
      :erlang.exit({:exception, :killed})
    end)

    assert {:error, :heap_limit_exceeded} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
  end

  test "maps an erpc execute-process kill to :heap_limit_exceeded without MFA fallback" do
    stub_exported(:ets_select_chunk, 3, true)

    expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_chunk, _, @timeout ->
      :erlang.exit({:signal, :killed})
    end)

    assert {:error, :heap_limit_exceeded} = Fetch.select_chunk(@node, :t, 10, nil, @timeout)
  end

  test "select_spec/6 maps a remote worker kill to :heap_limit_exceeded without MFA fallback" do
    spec = [{:"$1", [{:"=:=", {:element, 1, :"$1"}, :k}], [:"$1"]}]
    stub_exported(:ets_select_spec, 4, true)

    expect(Voyager.ErpcMock, :call, fn @node, :voyager_agent, :ets_select_spec, _, @timeout ->
      :erlang.error({:exception, :killed, []})
    end)

    assert {:error, :heap_limit_exceeded} = Fetch.select_spec(@node, :t, spec, 10, nil, @timeout)
  end

  defp stub_exported(fun, arity, exported?) do
    expect(Voyager.ErpcMock, :call, fn @node,
                                       :erlang,
                                       :function_exported,
                                       [:voyager_agent, ^fun, ^arity],
                                       _timeout ->
      exported?
    end)
  end
end
