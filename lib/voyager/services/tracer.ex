defmodule Voyager.Services.Tracer do
  @moduledoc """
  Runs at most one trace at a time and collects its events.

  The tracer on the remote node pushes event batches straight to this process.
  Events are kept in memory only (the newest 500) and broadcast on `topic/0`
  as `{:trace_events, trace, events}` and `{:trace_status, trace}`.
  """

  use GenServer

  alias Voyager.Agent

  @topic "tracing"
  @limits %{max_events: 10_000, max_rate: 1_000, max_time_ms: 60_000, budget: 500}
  @kept_events 500
  @max_mailbox 1_000
  @start_timeout 6_000

  @type spec :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer() | :any,
          capture: :arity | :args,
          local: boolean()
        }

  @type trace :: %{
          id: pos_integer(),
          node: node(),
          spec: spec(),
          tracer: pid(),
          status: :running | :stopped,
          reason: term(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          started_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec limits() :: map()
  def limits, do: @limits

  @doc "Starts a trace on `node`; `{:error, :busy}` while another one runs."
  @spec start(node(), spec()) :: {:ok, trace()} | {:error, term()}
  def start(node, spec),
    do: GenServer.call(__MODULE__, {:start, node, spec}, @start_timeout + 1_000)

  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "The current or last trace and its kept events, newest first."
  @spec current() :: {trace() | nil, [map()]}
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(nil), do: {:ok, %{trace: nil, events: [], dropped_here: 0}}

  @impl true
  def handle_call({:start, _node, _spec}, _from, %{trace: %{status: :running}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, node, spec}, _from, state) do
    case Agent.call(node, :trace_start, [self(), spec, @limits], @start_timeout) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        trace = %{
          id: System.unique_integer([:positive]),
          node: node,
          spec: spec,
          tracer: tracer,
          status: :running,
          reason: nil,
          events: 0,
          dropped: 0,
          started_at: DateTime.utc_now()
        }

        broadcast({:trace_status, trace})
        {:reply, {:ok, trace}, %{state | trace: trace, events: [], dropped_here: 0}}

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, %{trace: %{status: :running, tracer: tracer}} = state) do
    send(tracer, :voyager_trace_stop)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, state), do: {:reply, {state.trace, state.events}, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, dropped},
        %{trace: %{tracer: tracer} = trace} = state
      ) do
    if overloaded?() do
      dropped_here = state.dropped_here + length(events)
      trace = %{trace | dropped: dropped + dropped_here}
      {:noreply, %{state | trace: trace, dropped_here: dropped_here}}
    else
      events = Enum.with_index(events, fn event, i -> Map.put(event, :id, trace.events + i) end)

      trace = %{
        trace
        | events: trace.events + length(events),
          dropped: dropped + state.dropped_here
      }

      broadcast({:trace_events, trace, events})

      kept = Enum.take(Enum.reverse(events) ++ state.events, @kept_events)
      {:noreply, %{state | trace: trace, events: kept}}
    end
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{trace: %{tracer: tracer}} = state
      ) do
    {:noreply, finish(state, reason, dropped + state.dropped_here)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{trace: %{tracer: tracer, status: :running} = trace} = state
      ) do
    {:noreply, finish(state, {:tracer_down, reason}, trace.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp finish(state, reason, dropped) do
    trace = %{state.trace | status: :stopped, reason: reason, dropped: dropped}
    broadcast({:trace_status, trace})
    %{state | trace: trace}
  end

  # Batches are dropped here too, so a flood cannot grow this process' mailbox either.
  defp overloaded? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)
end
