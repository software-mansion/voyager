defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the single tracing session of this Voyager instance; the UI and MCP both go through it.

  A session is configured once, then switched on and off with `start/0` and
  `stop/0`; starting a stopped session resumes it. The tracer on the remote node
  pushes event batches straight to this process. The newest events are kept in
  memory and everything is broadcast on `topic/0` as
  `{:tracing_configured, session}`, `{:tracing_started, session}`,
  `{:trace_events, session, events}` and `{:tracing_ended, session}`.
  """

  use GenServer

  alias Voyager.Agent
  alias Voyager.Services.Tracer.Config

  @topic "tracing"
  @kept_events 500
  @max_mailbox 1_000
  @call_timeout Agent.default_timeout() + 1_000

  @type origin :: :ui | :mcp

  @type session :: %{
          id: pos_integer(),
          node: node(),
          config: Config.t(),
          origin: origin(),
          tracer: pid() | nil,
          status: :configured | :running | :stopped,
          stop_reason: term(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Replaces the session with a new one tracing `node` with `attrs` (see `Config`).
  Selected pids are resolved on `node` in the caller. Returns `{:error, :busy}` while a session runs.
  """
  @spec configure(node(), map(), origin()) ::
          {:ok, session()} | {:error, :busy | Ecto.Changeset.t() | term()}
  def configure(node, attrs, origin) when origin in [:ui, :mcp] do
    with {:ok, config} <- attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate),
         {:ok, pids} <- resolve_pids(node, config) do
      GenServer.call(
        __MODULE__,
        {:configure, node, config, Config.to_agent(config, pids), origin}
      )
    end
  end

  @doc "Starts or resumes the configured session; the agent's refusals come back as `{:error, reason}`."
  @spec start() :: {:ok, session()} | {:error, term()}
  def start, do: GenServer.call(__MODULE__, :start, @call_timeout)

  @doc """
  Asks the remote tracer to stop; `tracing_ended` follows with `:stopped`.
  Stops any session, whoever started it.
  """
  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop, @call_timeout)

  @doc """
  Ends a running session with `:disconnected` once its tracer goes down, without calling the node.
  The remote tracer stops by itself when this node disconnects.
  """
  @spec disconnected() :: :ok
  def disconnected, do: GenServer.cast(__MODULE__, :disconnected)

  @doc "The session and its kept events, newest first."
  @spec current() :: {session() | nil, [map()]}
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(nil),
    do: {:ok, %{session: nil, agent_args: nil, events: [], run: nil}}

  @impl true
  def handle_call(
        {:configure, _node, _config, _args, _origin},
        _from,
        %{session: %{status: :running}} = state
      ),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:configure, node, config, agent_args, origin}, _from, state) do
    session = %{
      id: System.unique_integer([:positive]),
      node: node,
      config: config,
      origin: origin,
      tracer: nil,
      status: :configured,
      stop_reason: nil,
      events: 0,
      dropped: 0,
      started_at: nil,
      ended_at: nil
    }

    broadcast({:tracing_configured, session})
    {:reply, {:ok, session}, %{state | session: session, agent_args: agent_args, events: []}}
  end

  def handle_call(:start, _from, %{session: nil} = state),
    do: {:reply, {:error, :not_configured}, state}

  def handle_call(:start, _from, %{session: %{status: :running}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:start, _from, %{session: session} = state) do
    {spec, limits} = state.agent_args

    case Agent.call(session.node, :trace_start, [self(), spec, limits], Agent.default_timeout()) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        session = %{
          session
          | tracer: tracer,
            status: :running,
            stop_reason: nil,
            started_at: session.started_at || DateTime.utc_now(),
            ended_at: nil
        }

        broadcast({:tracing_started, session})

        Voyager.Telemetry.dispatch!("voyager.trace.start",
          metadata:
            session.config
            |> Map.take([:capture, :scope, :return_trace, :processes])
            |> Map.put(:origin, session.origin)
        )

        run = %{
          events: session.events,
          dropped: session.dropped,
          dropped_here: 0,
          stopping: nil,
          at: System.monotonic_time()
        }

        {:reply, {:ok, session}, %{state | session: session, run: run}}

      {:ok, {:error, reason}} ->
        start_failed(reason, state)

      {:error, reason} ->
        start_failed(reason, state)
    end
  end

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call(:stop, _from, %{session: %{status: :running} = session} = state) do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    {:reply, :ok, %{state | run: %{state.run | stopping: :stopped}}}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, state), do: {:reply, {state.session, state.events}, state}

  @impl true
  def handle_cast(:disconnected, %{session: %{status: :running}} = state),
    do: {:noreply, %{state | run: %{state.run | stopping: :disconnected}}}

  def handle_cast(:disconnected, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, dropped},
        %{session: %{tracer: tracer, status: :running} = session, run: run} = state
      ) do
    {events, dropped_here} =
      if overloaded?(),
        do: {[], run.dropped_here + length(events)},
        else: {events, run.dropped_here}

    events = Enum.with_index(events, fn event, i -> Map.put(event, :id, session.events + i) end)

    session = %{
      session
      | events: session.events + length(events),
        dropped: run.dropped + dropped + dropped_here
    }

    if events != [], do: broadcast({:trace_events, session, events})

    kept = Enum.take(Enum.reverse(events) ++ state.events, @kept_events)

    {:noreply,
     %{state | session: session, events: kept, run: %{run | dropped_here: dropped_here}}}
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{session: %{tracer: tracer, status: :running}} = state
      ) do
    {:noreply, finish(state, reason, state.run.dropped + dropped + state.run.dropped_here)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    {:noreply, finish(state, down_reason(reason), session.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp finish(%{run: run} = state, reason, dropped) do
    session = %{
      state.session
      | status: :stopped,
        stop_reason: run.stopping || reason,
        dropped: dropped,
        ended_at: DateTime.utc_now()
    }

    broadcast({:tracing_ended, session})

    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: session.events - run.events,
        dropped: session.dropped - run.dropped,
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - run.at, :native, :millisecond)
      },
      metadata: %{origin: session.origin, reason: session.stop_reason}
    )

    %{state | session: session}
  end

  defp start_failed(reason, state) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: state.session.origin, reason: reason}
    )

    {:reply, {:error, reason}, state}
  end

  defp resolve_pids(_node, %Config{processes: processes}) when processes != :pids, do: {:ok, []}

  defp resolve_pids(node, config) do
    Enum.reduce_while(config.pids, {:ok, []}, fn pid_string, {:ok, pids} ->
      case Voyager.Pid.resolve(node, pid_string) do
        {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp down_reason(:noconnection), do: :node_down
  defp down_reason(reason), do: {:tracer_down, reason}

  # Batches are dropped here too, so a flood cannot grow this process' mailbox either.
  defp overloaded? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)
end
