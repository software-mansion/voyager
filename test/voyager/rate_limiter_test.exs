defmodule Voyager.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Voyager.RateLimiter

  setup do
    :sys.replace_state(RateLimiter, fn state ->
      %{
        state
        | tokens_high: 2,
          tokens_low: 2,
          last_refill_at: System.monotonic_time(:millisecond),
          ewma_ms: 0.0,
          low_refill_factor: 1.0,
          config: %{
            state.config
            | high_capacity: 2,
              low_capacity: 2,
              high_refill: 2,
              low_refill: 2,
              refill_interval_ms: 10_000,
              latency_threshold_ms: 3_000
          }
      }
    end)

    :ok
  end

  test "high priority succeeds when tokens are available" do
    assert {:ok, :res} = RateLimiter.run(:high, fn -> :res end)

    state = :sys.get_state(RateLimiter)
    assert state.tokens_high == 1
  end

  test "low priority succeeds when tokens are available and high priority isn't starving" do
    assert {:ok, :res} = RateLimiter.run(:low, fn -> :res end)

    state = :sys.get_state(RateLimiter)
    assert state.tokens_low == 1
  end

  test "low priority is rejected (starvation guard) if high priority has < 2 tokens" do
    assert {:ok, :res} = RateLimiter.run(:high, fn -> :res end)

    state = :sys.get_state(RateLimiter)
    assert state.tokens_high == 1

    assert {:error, :rate_limited, retry_ms} = RateLimiter.run(:low, fn -> :res end)
    assert retry_ms > 0
    assert retry_ms <= 10_000

    state = :sys.get_state(RateLimiter)
    assert state.tokens_low == 2
  end

  test "exhausting high priority returns rate_limited" do
    assert {:ok, _} = RateLimiter.run(:high, fn -> :res end)
    assert {:ok, _} = RateLimiter.run(:high, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(:high, fn -> :res end)
  end

  test "exhausting low priority returns rate_limited" do
    :sys.replace_state(RateLimiter, fn state -> %{state | tokens_high: 10} end)

    assert {:ok, _} = RateLimiter.run(:low, fn -> :res end)
    assert {:ok, _} = RateLimiter.run(:low, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(:low, fn -> :res end)
  end

  test "refill tick replenishes tokens" do
    assert {:ok, _} = RateLimiter.run(:high, fn -> :res end)
    assert {:ok, _} = RateLimiter.run(:high, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(:high, fn -> :res end)

    send(RateLimiter, :refill)

    assert {:ok, _} = RateLimiter.run(:high, fn -> :res end)
  end

  test "latency reporting over threshold tightens low refill factor" do
    GenServer.cast(RateLimiter, {:report_latency, 5_000_000})

    _ = :sys.get_state(RateLimiter)

    GenServer.cast(RateLimiter, {:report_latency, 20_000_000})
    _ = :sys.get_state(RateLimiter)

    state = :sys.get_state(RateLimiter)
    assert state.ewma_ms > 3_000
    assert state.low_refill_factor < 1.0
  end

  test "latency reporting under threshold relaxes low refill factor" do
    :sys.replace_state(RateLimiter, fn state ->
      %{state | ewma_ms: 1000.0, low_refill_factor: 0.5}
    end)

    GenServer.cast(RateLimiter, {:report_latency, 10_000})

    _ = :sys.get_state(RateLimiter)

    state = :sys.get_state(RateLimiter)
    assert state.low_refill_factor > 0.5
  end
end
