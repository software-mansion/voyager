defmodule Voyager.Services.Tracer.CallPairingTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.CallPairing

  @mfa {Enum, :map, 2}

  defp event(type, at, opts \\ []),
    do: %{type: type, at: at, pid: opts[:pid] || self(), mfa: opts[:mfa] || @mfa}

  test "gives a return the duration of its call" do
    {[call, ret], pairing} =
      CallPairing.pair(%CallPairing{}, [event(:call, 10), event(:return, 25)])

    refute Map.has_key?(call, :duration_us)
    assert ret.duration_us == 15
    assert pairing == %CallPairing{}
  end

  test "gives an exception the duration of its call" do
    {[_call, exc], _pairing} =
      CallPairing.pair(%CallPairing{}, [event(:call, 10), event(:exception, 14)])

    assert exc.duration_us == 4
  end

  test "pairs nested calls last in, first out" do
    {[_, _, inner_ret, outer_ret], pairing} =
      CallPairing.pair(%CallPairing{}, [
        event(:call, 1),
        event(:call, 5),
        event(:return, 8),
        event(:return, 20)
      ])

    assert inner_ret.duration_us == 3
    assert outer_ret.duration_us == 19
    assert pairing.count == 0
  end

  test "keeps open calls across batches" do
    {_events, pairing} = CallPairing.pair(%CallPairing{}, [event(:call, 1)])
    assert pairing.count == 1

    {[ret], pairing} = CallPairing.pair(pairing, [event(:return, 4)])
    assert ret.duration_us == 3
    assert pairing == %CallPairing{}
  end

  test "keys calls by pid and mfa" do
    other_pid = spawn(fn -> :ok end)

    {events, _pairing} =
      CallPairing.pair(%CallPairing{}, [
        event(:call, 1),
        event(:call, 2, mfa: {Enum, :map, 3}),
        event(:call, 3, pid: other_pid),
        event(:return, 10)
      ])

    assert List.last(events).duration_us == 9
  end

  test "passes an unmatched return through unchanged" do
    ret = event(:return, 5)
    assert {[^ret], %CallPairing{count: 0}} = CallPairing.pair(%CallPairing{}, [ret])
  end

  test "resets past the cap on the next batch, not within one" do
    calls = for at <- 1..10_001, do: event(:call, at)
    {_events, pairing} = CallPairing.pair(%CallPairing{}, calls)
    assert pairing.count == 10_001

    {[ret], pairing} = CallPairing.pair(pairing, [event(:return, 20_000)])
    refute Map.has_key?(ret, :duration_us)
    assert pairing == %CallPairing{}
  end

  describe "find_call/2" do
    test "finds a call event's outcome among the later events" do
      call = event(:call, 10)
      ret = :return |> event(25) |> Map.put(:duration_us, 15)

      assert CallPairing.find_call(call, [event(:call, 12, pid: spawn(fn -> :ok end)), ret]) ==
               %{call_event: call, outcome: ret}
    end

    test "finds an outcome's call event among the earlier events, past nested calls" do
      outer = event(:call, 1)
      inner_ret = :return |> event(8) |> Map.put(:duration_us, 3)
      outer_ret = :exception |> event(20) |> Map.put(:duration_us, 19)

      assert CallPairing.find_call(outer_ret, [inner_ret, event(:call, 5), outer]) ==
               %{call_event: outer, outcome: outer_ret}
    end

    test "finds no partner whose duration does not match, as after a drop" do
      call = event(:call, 10)
      unpaired = event(:return, 25)
      paired_elsewhere = :return |> event(30) |> Map.put(:duration_us, 2)

      assert CallPairing.find_call(call, [unpaired]) == %{call_event: call, outcome: nil}
      assert CallPairing.find_call(call, [paired_elsewhere]) == %{call_event: call, outcome: nil}
      assert CallPairing.find_call(unpaired, [call]) == %{call_event: nil, outcome: unpaired}
    end
  end

  test "does not reset at exactly the cap" do
    calls = for at <- 1..10_000, do: event(:call, at)
    {_events, pairing} = CallPairing.pair(%CallPairing{}, calls)

    {[ret], _pairing} = CallPairing.pair(pairing, [event(:return, 20_000)])
    assert ret.duration_us == 20_000 - 10_000
  end
end
