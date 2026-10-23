defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the active tracing session of this Voyager instance; the UI and MCP both go through it.

  A session is created, configured, then switched on and off with `start/1` and
  `stop/1`; starting a stopped session resumes it. The tracer on the remote node
  pushes event batches straight to this process. With `return_trace`, returns and
  exceptions get their call's `duration_us`.

  A session is a log of entries numbered by `seq`: `:configured`, `:started`,
  `:stopped`, `:trace` (a trace event) and `:dropped` (how many events were lost
  since the previous entry). The configured, started and stopped entries and the
  newest trace and dropped entries are kept in memory. Broadcasts on `topic/0` are
  `{:session_created, session}`, `{:session_closed, id}` and
  `{:session_entries, session, entries}` with the entries just appended, oldest first.

  A session created with `save: true` gets a `Voyager.Schemas.TraceSession` row and
  writes every entry as it is appended; `load/1` makes it active again later.
  Saved entries are capped by the `:trace_storage_limit_mb` setting: a run over it
  stops with `:storage_limit`, and older sessions are pruned when a run ends.
  """

  use GenServer

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Agent
  alias Voyager.Queries.TraceEntries, as: TraceEntryQueries
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Run
  alias Voyager.Services.Tracer.Session
  alias Voyager.Settings

  @topic "tracing"
  @kept_traces 500
  @max_mailbox 1_000
  # ponytail: never-returning calls leak, so open calls reset past this; per-key LRU if pairs go missing.
  @max_open_calls 10_000
  @call_timeout Agent.default_timeout() + 1_000
  @default_storage_limit_mb 100

  @type origin :: :ui | :mcp

  @type stop_reason ::
          :stopped
          | :disconnected
          | :event_limit
          | :rate_limit
          | :time_limit
          | :mailbox_limit
          | :storage_limit
          | :node_down
          | {:tracer_down, term()}

  @type entry :: %{
          required(:seq) => non_neg_integer(),
          required(:kind) => :configured | :started | :stopped | :dropped | :trace,
          required(:at) => integer(),
          optional(atom()) => term()
        }

  # `controls` keeps every configured/started/stopped entry, `traces` the newest
  # trace and dropped entries; both newest first.
  defstruct session: nil, run: nil, controls: [], traces: [], evicted_upto: -1

  @typep state :: %__MODULE__{
           session: Session.t() | nil,
           run: Run.t() | nil,
           controls: [entry()],
           traces: [entry()],
           evicted_upto: integer()
         }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Replaces the active session with a new, unconfigured one. Returns `{:error, :busy}` while it runs."
  @spec create(origin(), save: boolean()) :: {:ok, Session.t()} | {:error, :busy}
  def create(origin, opts \\ []) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:create, origin, Keyword.get(opts, :save, false)})

  @doc """
  Makes saved session `id` active, with its config, counts and newest entries.
  Returns `{:error, :busy}` while the active session runs.
  """
  @spec load(pos_integer()) :: {:ok, Session.t()} | {:error, :busy | :not_found}
  def load(id) when is_integer(id), do: GenServer.call(__MODULE__, {:load, id})

  @doc "Deletes saved session `id` and its entries, unloading it if active; the running one is refused."
  @spec delete(pos_integer()) ::
          {:ok, Voyager.Schemas.TraceSession.t()} | {:error, :busy | :not_found}
  def delete(id) when is_integer(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Closes the active session. Returns `{:error, :busy}` while it runs."
  @spec close() :: :ok | {:error, :busy}
  def close, do: GenServer.call(__MODULE__, :close)

  @doc """
  Sets the active session to trace `node` with `attrs` (see `Config`).
  Selected pids are resolved on `node` in the caller. Returns `{:error, :busy}` while it runs.
  """
  @spec configure(node(), map(), origin()) ::
          {:ok, Session.t()} | {:error, :no_session | :busy | Ecto.Changeset.t() | term()}
  def configure(node, attrs, origin) when origin in [:ui, :mcp] do
    with {:ok, config} <- attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate),
         {:ok, _pids} <- resolve_pids(node, config) do
      GenServer.call(__MODULE__, {:configure, node, config, origin})
    end
  end

  @doc """
  Starts or resumes the configured session, resolving its pids on the node again in the caller.
  The agent's refusals come back as `{:error, reason}`, and `{:error, :changed}` means the
  session was reconfigured meanwhile.
  """
  @spec start(origin()) :: {:ok, Session.t()} | {:error, term()}
  def start(origin) when origin in [:ui, :mcp] do
    case active() do
      nil ->
        {:error, :no_session}

      %Session{config: nil} ->
        {:error, :not_configured}

      %Session{status: :running} ->
        {:error, :busy}

      %Session{node: node, config: config} ->
        case resolve_pids(node, config) do
          {:ok, pids} ->
            args = Config.to_agent(config, pids)
            GenServer.call(__MODULE__, {:start, origin, node, config, args}, @call_timeout)

          {:error, reason} ->
            start_failed(reason, origin)
        end
    end
  end

  @doc """
  Asks the remote tracer to stop; a `:stopped` entry with reason `:stopped` follows.
  Stops any session, whoever started it.
  """
  @spec stop(origin()) :: :ok
  def stop(origin) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:stop, origin}, @call_timeout)

  @doc """
  Ends a running session with `:disconnected` once its tracer goes down, without calling the node.
  The remote tracer stops by itself when this node disconnects.
  """
  @spec disconnecting() :: :ok
  def disconnecting, do: GenServer.cast(__MODULE__, :disconnecting)

  @spec active() :: Session.t() | nil
  def active, do: GenServer.call(__MODULE__, :active)

  @doc """
  A page of up to `:limit` (100) entries of session `id` with `seq` in `[:since, :before)`.
  With `:since` the page starts there, oldest first; without it the page is the newest
  entries before `:before`, newest first. `truncated?` says entries in the range the page
  covers were evicted from memory; saved sessions are read from the database and never are.
  """
  @spec entries(pos_integer(),
          since: non_neg_integer(),
          before: non_neg_integer(),
          limit: pos_integer()
        ) ::
          {:ok, %{entries: [entry()], truncated?: boolean()}} | {:error, :not_found}
  def entries(id, opts \\ []) do
    opts = Keyword.validate!(opts, [:since, :before, limit: 100])

    case GenServer.call(__MODULE__, {:entries, id, opts}) do
      :saved -> saved_entries(id, opts)
      reply -> reply
    end
  end

  @impl true
  def init(nil) do
    TraceSessionActions.interrupt_running()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(request, _from, %{session: %Session{status: :running}} = state)
      when request == :close or
             (is_tuple(request) and elem(request, 0) in [:create, :load, :configure, :start]),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:create, origin, save}, _from, _state) do
    id =
      if save do
        {:ok, row} = TraceSessionActions.create(%{origin: origin, status: :idle})
        row.id
      else
        -System.unique_integer([:positive])
      end

    session = %Session{
      id: id,
      origin: origin,
      save: save,
      created_at: DateTime.utc_now(),
      storage_limit: storage_limit()
    }

    broadcast({:session_created, session})
    {:reply, {:ok, session}, %__MODULE__{session: session}}
  end

  def handle_call({:load, id}, _from, state) do
    case TraceSessionQueries.get(id) do
      nil -> {:reply, {:error, :not_found}, state}
      row -> loaded(row)
    end
  end

  def handle_call({:delete, id}, _from, %{session: %{id: id, status: :running}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:delete, id}, _from, %{session: %{id: id}}) do
    broadcast({:session_closed, id})
    {:reply, TraceSessionActions.delete(id), %__MODULE__{}}
  end

  def handle_call({:delete, id}, _from, state),
    do: {:reply, TraceSessionActions.delete(id), state}

  def handle_call(:close, _from, %{session: nil} = state), do: {:reply, :ok, state}

  def handle_call(:close, _from, %{session: session}) do
    broadcast({:session_closed, session.id})
    {:reply, :ok, %__MODULE__{}}
  end

  def handle_call(request, _from, %{session: nil} = state)
      when elem(request, 0) in [:configure, :start],
      do: {:reply, {:error, :no_session}, state}

  def handle_call({:configure, node, config, origin}, _from, state) do
    state =
      %{state | session: %{state.session | node: node, config: config}}
      |> append([entry(:configured, origin, node: node, config: config)])

    {:reply, {:ok, state.session}, state}
  end

  def handle_call(
        {:start, origin, node, config, {spec, limits}},
        _from,
        %{session: %Session{node: node, config: config} = session} = state
      ) do
    case Agent.call(session.node, :trace_start, [self(), spec, limits], Agent.default_timeout()) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        session = %{
          session
          | tracer: tracer,
            status: :running,
            stop_reason: nil,
            started_at: session.started_at || DateTime.utc_now(),
            stopped_at: nil
        }

        Voyager.Telemetry.dispatch!("voyager.trace.start",
          metadata:
            session.config
            |> Map.take([:capture, :scope, :return_trace, :processes])
            |> Map.put(:origin, origin)
        )

        run = %Run{
          origin: origin,
          traces_before: session.traces,
          dropped_before: session.dropped,
          started_ms: System.monotonic_time(:millisecond)
        }

        state =
          append(%{state | session: session, run: run}, [entry(:started, origin)])

        {:reply, {:ok, state.session}, state}

      {:ok, {:error, reason}} ->
        {:reply, start_failed(reason, origin), state}

      {:error, reason} ->
        {:reply, start_failed(reason, origin), state}
    end
  end

  def handle_call({:start, _origin, _node, _config, _args}, _from, state),
    do: {:reply, {:error, :changed}, state}

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call({:stop, origin}, _from, %{session: %{status: :running} = session} = state) do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    {:reply, :ok, %{state | run: %{state.run | stop_request: {:stopped, origin}}}}
  end

  def handle_call({:stop, _origin}, _from, state), do: {:reply, :ok, state}

  def handle_call(:active, _from, state), do: {:reply, state.session, state}

  def handle_call(
        {:entries, id, opts},
        _from,
        %{session: %{id: id, save: false} = session} = state
      ) do
    since = Keyword.get(opts, :since, 0)
    before = Keyword.get(opts, :before, session.seq)
    order = if Keyword.has_key?(opts, :since), do: :asc, else: :desc

    page =
      (state.controls ++ state.traces)
      |> Enum.filter(&(&1.seq >= since and &1.seq < before))
      |> Enum.sort_by(& &1.seq, order)
      |> Enum.take(opts[:limit])

    # A full page covers the range up to its last entry; a short one the whole range.
    covered =
      case {order, length(page) == opts[:limit]} do
        {:asc, true} -> since..List.last(page).seq//1
        {:desc, true} -> List.last(page).seq..(before - 1)//1
        _short -> since..(before - 1)//1
      end

    {:reply, {:ok, %{entries: page, truncated?: evicted_in?(state, covered)}}, state}
  end

  def handle_call({:entries, _id, _opts}, _from, state), do: {:reply, :saved, state}

  @impl true
  def handle_cast(:disconnecting, %{session: %{status: :running}} = state),
    do: {:noreply, %{state | run: %{state.run | stop_request: {:disconnected, nil}}}}

  def handle_cast(:disconnecting, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, agent_dropped},
        %{session: %{tracer: tracer, status: :running} = session, run: run} = state
      ) do
    {events, shed} =
      if overloaded?(),
        do: {[], run.shed + length(events)},
        else: {events, run.shed}

    {events, open_calls} =
      if session.config.return_trace,
        do: pair_returns(events, run.open_calls),
        else: {events, run.open_calls}

    dropped = run.dropped_before + agent_dropped + shed

    session = %{session | traces: session.traces + length(events), dropped: dropped}

    state =
      %{state | session: session, run: %{run | shed: shed, open_calls: open_calls}}
      |> append(
        dropped_entry(dropped - state.session.dropped) ++
          Enum.map(events, &Map.put(&1, :kind, :trace))
      )

    {:noreply, stop_over_limit(state)}
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{session: %{tracer: tracer, status: :running}} = state
      ) do
    {:noreply, end_run(state, reason, state.run.dropped_before + dropped + state.run.shed)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    {:noreply, end_run(state, down_reason(reason), session.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  @spec end_run(state(), stop_reason(), non_neg_integer()) :: state()
  defp end_run(%{run: run} = state, reason, dropped) do
    {reason, origin} = run.stop_request || {reason, nil}

    session = %{
      state.session
      | status: :stopped,
        stop_reason: reason,
        dropped: dropped,
        stopped_at: DateTime.utc_now()
    }

    run_traces = session.traces - run.traces_before
    run_dropped = session.dropped - run.dropped_before

    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: run_traces,
        dropped: run_dropped,
        duration_ms: System.monotonic_time(:millisecond) - run.started_ms
      },
      metadata: %{origin: run.origin, reason: reason}
    )

    state =
      append(
        %{state | session: session, run: nil},
        dropped_entry(session.dropped - state.session.dropped) ++
          [entry(:stopped, origin, reason: reason, traces: run_traces, dropped: run_dropped)]
      )

    # ponytail: pruning only when a run ends lets disk peak near 2x the limit; prune per batch if that bites.
    if session.save, do: TraceSessionActions.prune(session.storage_limit, session.id)

    state
  end

  defp stop_over_limit(%{session: session, run: %Run{stop_request: nil} = run} = state)
       when session.bytes > session.storage_limit do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    %{state | run: %{run | stop_request: {:storage_limit, nil}}}
  end

  defp stop_over_limit(state), do: state

  defp storage_limit,
    do: Settings.get(:trace_storage_limit_mb, @default_storage_limit_mb) * 1_000_000

  defp pair_returns(events, open_calls) do
    open_calls = if map_size(open_calls) > @max_open_calls, do: %{}, else: open_calls
    Enum.map_reduce(events, open_calls, &pair_return/2)
  end

  defp pair_return(%{type: :call} = event, open_calls),
    do: {event, Map.update(open_calls, {event.pid, event.mfa}, [event.at], &[event.at | &1])}

  defp pair_return(event, open_calls) do
    key = {event.pid, event.mfa}

    case open_calls do
      %{^key => [at | rest]} ->
        open_calls =
          if rest == [], do: Map.delete(open_calls, key), else: Map.put(open_calls, key, rest)

        {Map.put(event, :duration_us, event.at - at), open_calls}

      _no_call ->
        {event, open_calls}
    end
  end

  defp loaded(row) do
    controls = TraceEntryQueries.controls(row.id)
    configured = Enum.find(controls, &(&1.kind == :configured)) || %{node: nil, config: nil}

    session = %Session{
      id: row.id,
      origin: row.origin,
      save: true,
      created_at: DateTime.from_naive!(row.inserted_at, "Etc/UTC"),
      node: configured.node,
      config: configured.config,
      status: row.status,
      stop_reason: row.stop_reason,
      traces: row.traces,
      dropped: row.dropped,
      bytes: row.bytes,
      storage_limit: storage_limit(),
      seq: TraceEntryQueries.next_seq(row.id),
      started_at: row.started_at,
      stopped_at: row.stopped_at
    }

    broadcast({:session_created, session})

    state = %__MODULE__{
      session: session,
      controls: controls,
      traces: TraceEntryQueries.traces(row.id, @kept_traces)
    }

    {:reply, {:ok, session}, state}
  end

  defp saved_entries(id, opts) do
    if TraceSessionQueries.get(id),
      do: {:ok, %{entries: TraceEntryQueries.page(id, opts), truncated?: false}},
      else: {:error, :not_found}
  end

  defp start_failed(reason, origin) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: origin, reason: reason}
    )

    {:error, reason}
  end

  defp entry(kind, origin, fields \\ []),
    do:
      Map.merge(%{kind: kind, origin: origin, at: System.os_time(:microsecond)}, Map.new(fields))

  # Only trace and dropped entries are evicted, oldest first, so every seq up to
  # `evicted_upto` that is not a kept control entry is gone.
  @spec evicted_in?(state(), Range.t()) :: boolean()
  defp evicted_in?(state, lo..hi//1) do
    top = min(hi, state.evicted_upto)
    top >= lo and top - lo + 1 > Enum.count(state.controls, &(&1.seq in lo..top//1))
  end

  defp dropped_entry(0), do: []
  defp dropped_entry(count), do: [entry(:dropped, nil, count: count)]

  # Dropped entries come with every shed batch, so they are capped with the traces.
  @spec append(state(), [entry()]) :: state()
  defp append(%__MODULE__{session: session} = state, entries) do
    entries = Enum.with_index(entries, &Map.put(&1, :seq, session.seq + &2))
    session = %{session | seq: session.seq + length(entries)}

    {traces, controls} =
      Enum.split_with(entries, &(&1.kind in [:trace, :dropped]))

    session = save(session, entries)
    broadcast({:session_entries, session, entries})

    {kept, evicted} = Enum.split(Enum.reverse(traces) ++ state.traces, @kept_traces)

    %{
      state
      | session: session,
        controls: Enum.reverse(controls) ++ state.controls,
        traces: kept,
        evicted_upto: if(evicted == [], do: state.evicted_upto, else: hd(evicted).seq)
    }
  end

  defp save(%Session{save: true} = session, entries) do
    {:ok, session} =
      Repo.transact(fn ->
        session = %{
          session
          | bytes: session.bytes + TraceEntryActions.insert_all(session.id, entries)
        }

        TraceSessionActions.sync(session)
        {:ok, session}
      end)

    session
  end

  defp save(session, _entries), do: session

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
