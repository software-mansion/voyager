defmodule Voyager.RateLimiter do
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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs the given function if the rate limit for the specified priority allows it.
  Returns `{:ok, result}` on success, or `{:error, :rate_limited, retry_after_ms}`.
  """
  @spec run(priority(), (-> result)) ::
          {:ok, result} | {:error, :rate_limited, non_neg_integer()}
  def run(priority, fun) when priority in [:high, :low] and is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:acquire, priority}) do
      :ok ->
        {elapsed_us, result} = :timer.tc(fun)
        GenServer.cast(__MODULE__, {:report_latency, elapsed_us})
        {:ok, result}

      {:error, retry_after_ms} ->
        {:error, :rate_limited, retry_after_ms}
    end
  end

  @default_config %{
    high_capacity: 20,
    high_refill: 20,
    low_capacity: 5,
    low_refill: 5,
    refill_interval_ms: 1_000,
    latency_threshold_ms: 3_000
  }

  @impl GenServer
  def init(_opts) do
    state = %{
      config: @default_config,
      tokens_high: @default_config.high_capacity,
      tokens_low: @default_config.low_capacity,
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
    if state.tokens_high < 2 do
      # Starvation guard: if high is running low, refuse low priority traffic.
      {:reply, {:error, retry_after(state)}, state}
    else
      if state.tokens_low > 0 do
        {:reply, :ok, %{state | tokens_low: state.tokens_low - 1}}
      else
        {:reply, {:error, retry_after(state)}, state}
      end
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
    low_refill_actual = trunc(state.config.low_refill * state.low_refill_factor)

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
