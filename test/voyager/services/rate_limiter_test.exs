defmodule Voyager.Services.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.RateLimiter

  @test_config %{
    high_capacity: 2,
    high_refill: 2,
    low_capacity: 2,
    low_refill: 2,
    low_starvation_threshold: 2,
    refill_interval_ms: 60_000,
    latency_threshold_ms: 3_000
  }

  setup do
    name = :"rate_limiter_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {RateLimiter, name: name, config: @test_config},
        id: name
      )

    %{server: name, pid: pid}
  end

  test "high priority succeeds when tokens are available", %{server: server} do
    assert {:ok, :res, _elapsed_us} = RateLimiter.run(server, :high, fn -> :res end)

    state = :sys.get_state(server)
    assert state.tokens_high == 1
  end

  test "low priority succeeds when tokens are available and high priority isn't starving",
       %{server: server} do
    assert {:ok, :res, _elapsed_us} = RateLimiter.run(server, :low, fn -> :res end)

    state = :sys.get_state(server)
    assert state.tokens_low == 1
  end

  test "low priority is rejected (starvation guard) if high priority has < threshold tokens",
       %{server: server} do
    assert {:ok, :res, _elapsed_us} = RateLimiter.run(server, :high, fn -> :res end)

    state = :sys.get_state(server)
    assert state.tokens_high == 1

    assert {:error, :rate_limited, retry_ms} = RateLimiter.run(server, :low, fn -> :res end)
    assert retry_ms > 0
    assert retry_ms <= 60_000

    state = :sys.get_state(server)
    assert state.tokens_low == 2
  end

  test "exhausting high priority returns rate_limited", %{server: server} do
    assert {:ok, _, _} = RateLimiter.run(server, :high, fn -> :res end)
    assert {:ok, _, _} = RateLimiter.run(server, :high, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(server, :high, fn -> :res end)
  end

  test "exhausting low priority returns rate_limited" do
    name = :"rate_limiter_low_exhaust_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RateLimiter,
       name: name,
       config: %{@test_config | high_capacity: 10, high_refill: 10, low_starvation_threshold: 2}},
      id: name
    )

    assert {:ok, _, _} = RateLimiter.run(name, :low, fn -> :res end)
    assert {:ok, _, _} = RateLimiter.run(name, :low, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(name, :low, fn -> :res end)
  end

  test "refill tick replenishes tokens", %{server: server} do
    assert {:ok, _, _} = RateLimiter.run(server, :high, fn -> :res end)
    assert {:ok, _, _} = RateLimiter.run(server, :high, fn -> :res end)
    assert {:error, :rate_limited, _} = RateLimiter.run(server, :high, fn -> :res end)

    send(server, :refill)
    # Sync to ensure the refill message was processed
    _ = :sys.get_state(server)

    assert {:ok, _, _} = RateLimiter.run(server, :high, fn -> :res end)
  end

  test "latency reporting over threshold tightens low refill factor", %{server: server} do
    GenServer.cast(server, {:report_latency, 5_000_000})
    _ = :sys.get_state(server)

    GenServer.cast(server, {:report_latency, 20_000_000})
    _ = :sys.get_state(server)

    state = :sys.get_state(server)
    assert state.ewma_ms > 3_000
    assert state.low_refill_factor < 1.0
  end

  test "latency reporting under threshold relaxes low refill factor", %{server: server} do
    :sys.replace_state(server, fn state ->
      %{state | ewma_ms: 1000.0, low_refill_factor: 0.5}
    end)

    GenServer.cast(server, {:report_latency, 10_000})
    _ = :sys.get_state(server)

    state = :sys.get_state(server)
    assert state.low_refill_factor > 0.5
  end

  test "latency is reported even when function raises", %{server: server} do
    assert_raise RuntimeError, fn ->
      RateLimiter.run(server, :high, fn -> raise "boom" end)
    end

    # The cast was sent before the exception propagated — sync with the server
    state = :sys.get_state(server)
    assert state.ewma_ms > 0.0
  end

  test "low refill never drops to zero when low_refill is positive", %{server: server} do
    :sys.replace_state(server, fn state ->
      %{state | low_refill_factor: 0.05, tokens_low: 0}
    end)

    send(server, :refill)
    _ = :sys.get_state(server)

    state = :sys.get_state(server)
    assert state.tokens_low >= 1
  end
end
