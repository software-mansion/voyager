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

  test "does not reset at exactly the cap" do
    calls = for at <- 1..10_000, do: event(:call, at)
    {_events, pairing} = CallPairing.pair(%CallPairing{}, calls)

    {[ret], _pairing} = CallPairing.pair(pairing, [event(:return, 20_000)])
    assert ret.duration_us == 20_000 - 10_000
  end
end
