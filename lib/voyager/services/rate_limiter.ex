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

  @default_config %{
    high_capacity: 5,
    high_refill: 2,
    low_capacity: 2,
    low_refill: 1,
    low_starvation_threshold: 2,
    refill_interval_ms: 1_000
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs the given function if the rate limit for the specified priority allows it.
  Returns `{:ok, result, elapsed_us}` on success, or `{:error, :rate_limited, retry_after_ms}`.
  """
  @spec run(GenServer.server(), priority(), (-> result)) ::
          {:ok, result, non_neg_integer()} | {:error, :rate_limited, non_neg_integer()}
  def run(server \\ __MODULE__, priority, fun)
      when priority in [:high, :low] and is_function(fun, 0) do
    case GenServer.call(server, {:acquire, priority}) do
      :ok ->
        start = System.monotonic_time(:microsecond)
        result = fun.()
        {:ok, result, System.monotonic_time(:microsecond) - start}

      {:error, retry_after_ms} ->
        {:error, :rate_limited, retry_after_ms}
    end
  end

  @impl GenServer
  def init(opts) do
    user_config = Keyword.get(opts, :config, %{})
    config = @default_config |> Map.merge(user_config) |> cap_refills()

    state = %{
      config: config,
      tokens_high: config.high_capacity,
      tokens_low: config.low_capacity,
      last_refill_at: System.monotonic_time(:millisecond),
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
  def handle_info(:refill, state) do
    now = System.monotonic_time(:millisecond)

    new_state =
      state
      |> Map.put(
        :tokens_high,
        min(state.config.high_capacity, state.tokens_high + state.config.high_refill)
      )
      |> Map.put(
        :tokens_low,
        min(state.config.low_capacity, state.tokens_low + state.config.low_refill)
      )
      |> Map.put(:last_refill_at, now)
      |> schedule_refill()

    {:noreply, new_state}
  end

  defp cap_refills(config) do
    %{
      config
      | high_refill: min(config.high_refill, config.high_capacity),
        low_refill: min(config.low_refill, config.low_capacity)
    }
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
