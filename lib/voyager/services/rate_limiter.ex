defmodule Voyager.Services.RateLimiter do
  @moduledoc """
  Global token-bucket rate limiter for remote-node introspection calls.

  Two priority tiers:
  - `:high` — manual GUI actions + MCP tool calls
  - `:low`  — background auto-refresh (yields to `:high` traffic)

  ## Usage

      RateLimiter.run(:high, fn -> ProcessInfo.fetch(node, pid) end)
      RateLimiter.run(:low,  fn -> NodeInfo.fetch(node) end)
  """

  use GenServer

  @type priority :: :high | :low
  @type result :: term()

  @ewma_alpha 0.3
  @default_config %{
    high_capacity: 10,
    high_refill: 5,
    low_capacity: 2,
    low_refill: 1,
    low_starvation_threshold: 2,
    refill_interval_ms: 1_000,
    latency_threshold_ms: 3_000
  }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs the given function if the rate limit for the specified priority allows it.
  Returns `{:ok, result, elapsed_us}` on success, or `{:error, :rate_limited, retry_after_ms}`.
  """
  @spec run(priority(), (-> result)) ::
          {:ok, result, non_neg_integer()} | {:error, :rate_limited, non_neg_integer()}
  def run(priority, fun) when priority in [:high, :low] and is_function(fun, 0) do
    run(__MODULE__, priority, fun)
  end

  @doc """
  Like `run/2`, but targets a specific named server.
  """
  @spec run(GenServer.server(), priority(), (-> result)) ::
          {:ok, result, non_neg_integer()} | {:error, :rate_limited, non_neg_integer()}
  def run(server, priority, fun) when priority in [:high, :low] and is_function(fun, 0) do
    case GenServer.call(server, {:acquire, priority}) do
      :ok ->
        start = System.monotonic_time(:microsecond)

        try do
          result = fun.()
          elapsed_us = System.monotonic_time(:microsecond) - start
          {:ok, result, elapsed_us}
        after
          elapsed_us = System.monotonic_time(:microsecond) - start
          GenServer.cast(server, {:report_latency, elapsed_us})
        end

      {:error, retry_after_ms} ->
        {:error, :rate_limited, retry_after_ms}
    end
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.get(opts, :config, @default_config)

    state = %{
      config: config,
      tokens_high: config.high_capacity,
      tokens_low: config.low_capacity,
      last_refill_at: System.monotonic_time(:millisecond),
      ewma_ms: 0.0,
      low_refill_factor: 1.0,
      timer_ref: nil
    }

    {:ok, schedule_refill(state)}
  end

  @impl GenServer
  def handle_call({:acquire, :high}, _from, state) do
    if state.tokens_high > 0 do
      {:reply, :ok, %{state | tokens_high: state.tokens_high - 1}}
    else
      {:reply, {:error, retry_after(state)}, state}
    end
  end

  def handle_call({:acquire, :low}, _from, state) do
    cond do
      state.tokens_high < state.config.low_starvation_threshold ->
        # Starvation guard: if high is running low, refuse low priority traffic.
        {:reply, {:error, retry_after(state)}, state}

      state.tokens_low > 0 ->
        {:reply, :ok, %{state | tokens_low: state.tokens_low - 1}}

      true ->
        {:reply, {:error, retry_after(state)}, state}
    end
  end

  @impl GenServer
  def handle_cast({:report_latency, elapsed_us}, state) do
    elapsed_ms = elapsed_us / 1000.0
    new_ewma = @ewma_alpha * elapsed_ms + (1.0 - @ewma_alpha) * state.ewma_ms

    factor =
      if new_ewma > state.config.latency_threshold_ms do
        max(state.low_refill_factor * 0.5, 0.1)
      else
        min(state.low_refill_factor * 1.1, 1.0)
      end

    {:noreply, %{state | ewma_ms: new_ewma, low_refill_factor: factor}}
  end

  @impl GenServer
  def handle_info(:refill, state) do
    now = System.monotonic_time(:millisecond)

    low_refill_actual =
      if state.config.low_refill > 0 do
        max(trunc(state.config.low_refill * state.low_refill_factor), 1)
      else
        0
      end

    new_state =
      state
      |> Map.put(
        :tokens_high,
        min(state.config.high_capacity, state.tokens_high + state.config.high_refill)
      )
      |> Map.put(
        :tokens_low,
        min(state.config.low_capacity, state.tokens_low + low_refill_actual)
      )
      |> Map.put(:last_refill_at, now)
      |> schedule_refill()

    {:noreply, new_state}
  end

  defp schedule_refill(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :refill, state.config.refill_interval_ms)
    %{state | timer_ref: ref}
  end

  defp retry_after(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_refill_at
    max(state.config.refill_interval_ms - elapsed, 0)
  end
end
