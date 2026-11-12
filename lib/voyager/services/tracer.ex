defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the active tracing session of this Voyager instance; the UI and MCP both go through it.

  A session is created, configured, then switched on and off with `start/1` and
  `stop/1`; starting a stopped session resumes it. The tracer on the remote node
  pushes event batches straight to this process. With `return_trace`, returns and
  exceptions get their call's `duration_us`.

  A session is a log of entries numbered by `seq`: `:configured`, `:started`,
  `:stopped`, `:trace` (a trace event) and `:dropped` (how many events were lost
  since the previous entry). A `:configured` entry's `previous` is the config it
  replaced, nil for the first. The configured, started and stopped entries and the
  newest trace and dropped entries are kept in memory while a session is unsaved;
  saved sessions are read from the database. Broadcasts on `topic/0` are
  `{:session_activated, session}`, `{:session_closed, id}` and
  `{:session_entries, session, entries}` with the entries just appended, oldest first.
  `session_topic/0` carries only `{:session_updated, session | nil}` alongside each of those.

  A session created with `save: true` gets a `Voyager.Schemas.TraceSession` row and
  every entry is handed to `Writer` as it is appended; `load/1` makes it active again later.
  Saved sessions share the `:trace_storage_limit_mb` setting as a total budget: a run
  gets what is left after the other saved sessions and stops with `:storage_limit`
  once that runs out.
  """

  use GenServer

  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Agent
  alias Voyager.Queries.TraceEntries, as: TraceEntryQueries
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.MemoryLog
  alias Voyager.Services.Tracer.Run
  alias Voyager.Services.Tracer.Search
  alias Voyager.Services.Tracer.Session
  alias Voyager.Services.Tracer.Summary
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Settings

  @topic "tracing"
  @session_topic "tracing:session"
  @max_mailbox 1_000
  @call_timeout Agent.default_timeout() + 1_000
  @default_storage_limit_mb 100
  @kept_traces MemoryLog.kept_traces()

  @type origin :: :ui | :mcp

  @type stop_reason ::
          :stopped
          | :disconnected
          | :event_limit
          | :rate_limit
          | :time_limit
          | :mailbox_limit
          | :storage_limit
          | :write_failed
          | :interrupted
          | :node_down
          | {:tracer_down, term()}

  defstruct session: nil, run: nil, log: %MemoryLog{}

  @typep state :: %__MODULE__{
           session: Session.t() | nil,
           run: Run.t() | nil,
           log: MemoryLog.t()
         }

  defguardp is_session_change(request)
            when request == :close or
                   (is_tuple(request) and
                      elem(request, 0) in [:create, :load, :configure, :start])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec session_topic() :: String.t()
  def session_topic, do: @session_topic

  @doc "Replaces the active session with a new, unconfigured one. Returns `{:error, :busy}` while it runs."
  @spec create(origin(), save: boolean()) :: {:ok, Session.t()} | {:error, :busy}
  def create(origin, opts \\ []) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:create, origin, Keyword.get(opts, :save, false)})

  @doc """
  Makes saved session `id` active, with its config and counts.
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
    with {:ok, %{node: node, config: config}} <- startable(active()) do
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
  def stop(origin) when origin in [:ui, :mcp] do
    with {:ok, node, tracer} <- GenServer.call(__MODULE__, {:stop, origin}) do
      stop_tracer(node, tracer)
    end

    :ok
  end

  @doc """
  Ends a running session with `:disconnected` once its tracer goes down, without calling the node.
  The remote tracer stops by itself when this node disconnects.
  """
  @spec disconnecting() :: :ok
  def disconnecting, do: GenServer.cast(__MODULE__, :disconnecting)

  @spec active() :: Session.t() | nil
  def active, do: GenServer.call(__MODULE__, :active)

  @doc "Session `id`, and whether it is the `:active` one or only `:saved`. The database is read in the caller."
  @spec session(integer()) :: {:ok, Session.t(), :active | :saved} | {:error, :not_found}
  def session(id) when is_integer(id) do
    case active() do
      %Session{id: ^id} = session -> {:ok, session, :active}
      _other -> with_saved(id, &{:ok, saved_session(&1), :saved})
    end
  end

  @doc "The total budget in MB that saved sessions share."
  @spec storage_limit_mb() :: non_neg_integer()
  def storage_limit_mb, do: Settings.get(:trace_storage_limit_mb, @default_storage_limit_mb)

  @spec kept_traces() :: pos_integer()
  defdelegate kept_traces, to: MemoryLog

  @doc """
  A page of up to `:limit` (default 100, at least 1) entries of session `id` with `seq` in
  `[:since, :before)` (integers >= 0). `:order` is `:desc` (default) for the newest entries of the
  range first or `:asc` for the oldest first. `truncated?` says entries in the range the page
  covers were evicted from memory; saved sessions are read from the database and never are.
  Raises `ArgumentError` on an unknown option or a bad value.
  """
  @spec entries(integer(),
          since: non_neg_integer(),
          before: non_neg_integer(),
          order: :asc | :desc,
          limit: pos_integer()
        ) ::
          {:ok, %{entries: [Entry.t()], truncated?: boolean()}} | {:error, :not_found}
  def entries(id, opts \\ []) do
    opts = Keyword.validate!(opts, [:since, :before, order: :desc, limit: 100])
    Enum.each(opts, fn {key, value} -> validate_entries_opt!(key, value) end)

    case GenServer.call(__MODULE__, {:entries, id, opts}) do
      :saved ->
        with_saved(id, fn _row ->
          {:ok, %{entries: TraceEntryQueries.page(id, opts), truncated?: false}}
        end)

      reply ->
        reply
    end
  end

  @doc """
  Up to `:limit` (default 100) trace entries of session `id` containing `query`, ignoring ASCII
  case, with `seq` below `:before`, newest first. Runs in the caller. A saved session searches
  all its traces, an unsaved one the at most #{@kept_traces} still in memory. `total` counts
  every match, and is nil once `:before` is given. Raises `ArgumentError` on an unknown option
  or a bad value.
  """
  @spec search(integer(), String.t(), before: non_neg_integer(), limit: pos_integer()) ::
          {:ok, %{entries: [Entry.t()], total: non_neg_integer() | nil}} | {:error, :not_found}
  def search(id, query, opts \\ []) do
    opts = Keyword.validate!(opts, [:before, limit: 100])
    Enum.each(opts, fn {key, value} -> validate_entries_opt!(key, value) end)
    query = Search.query(query)

    if id > 0 do
      with_saved(id, fn _row -> {:ok, TraceEntryQueries.search(id, query, opts)} end)
    else
      with {:ok, traces} <- GenServer.call(__MODULE__, {:kept_traces, id}),
           do: {:ok, Search.filter(traces, query, opts)}
    end
  end

  @doc "The `Summary` of every trace event of session `id`, including those evicted from memory."
  @spec summary(integer()) :: {:ok, Summary.t()} | {:error, :not_found}
  def summary(id) do
    case GenServer.call(__MODULE__, {:summary, id}) do
      :saved -> with_saved(id, fn _row -> {:ok, TraceEntryQueries.summary(id)} end)
      reply -> reply
    end
  end

  @impl true
  def init(nil), do: {:ok, %__MODULE__{}, {:continue, :interrupt_running}}

  @impl true
  def handle_continue(:interrupt_running, state) do
    Writer.flush()
    TraceSessionActions.interrupt_running()
    broadcast_session(nil)
    {:noreply, state}
  end

  @impl true
  def handle_call(request, _from, %{session: %Session{status: :running}} = state)
      when is_session_change(request),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:create, origin, save}, _from, _state) do
    origin
    |> new_session(save)
    |> activate()
  end

  def handle_call({:load, id}, _from, state) do
    Writer.flush()
    TraceSessionActions.interrupt_running()

    case TraceSessionQueries.get(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      row ->
        row
        |> saved_session()
        |> activate()
    end
  end

  def handle_call({:delete, id}, _from, %{session: %{id: id, status: :running}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:delete, id}, _from, %{session: %{id: id, save: true}}) do
    Writer.flush()
    broadcast({:session_closed, id})
    broadcast_session(nil)
    {:reply, TraceSessionActions.delete(id), %__MODULE__{}}
  end

  def handle_call({:delete, id}, _from, state) do
    Writer.flush()
    {:reply, TraceSessionActions.delete(id), state}
  end

  def handle_call(:close, _from, %{session: nil} = state), do: {:reply, :ok, state}

  def handle_call(:close, _from, %{session: session}) do
    broadcast({:session_closed, session.id})
    broadcast_session(nil)
    {:reply, :ok, %__MODULE__{}}
  end

  def handle_call({:configure, _node, _config, _origin}, _from, %{session: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call({:configure, node, config, origin}, _from, state) do
    state =
      %{state | session: %{state.session | node: node, config: config}}
      |> append([Entry.configured(origin, node, config, state.session.config)])

    {:reply, {:ok, state.session}, state}
  end

  def handle_call({:start, _origin, _node, _config, _args}, _from, %{session: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  # The caller resolved the pids, so `node` and `config` must still be the session's.
  def handle_call(
        {:start, origin, node, config, {spec, limits}},
        _from,
        %{session: %Session{node: node, config: config} = session} = state
      ) do
    case start_tracer(session, spec, limits) do
      {:ok, tracer} ->
        state = begin_run(state, tracer, origin)
        {:reply, {:ok, state.session}, state}

      {:error, reason} ->
        {:reply, start_failed(reason, origin), state}
    end
  end

  def handle_call({:start, _origin, _node, _config, _args}, _from, state),
    do: {:reply, {:error, :changed}, state}

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call({:stop, origin}, _from, %{session: %{status: :running} = session} = state) do
    {:reply, {:ok, session.node, session.tracer}, put_stop_request(state, :stopped, origin)}
  end

  def handle_call({:stop, _origin}, _from, state), do: {:reply, :ok, state}

  def handle_call(:active, _from, state), do: {:reply, state.session, state}

  def handle_call(
        {:entries, id, opts},
        _from,
        %{session: %{id: id, save: false} = session} = state
      ) do
    {:reply, {:ok, MemoryLog.page(state.log, session.seq, opts)}, state}
  end

  def handle_call({:entries, _id, _opts}, _from, state), do: {:reply, :saved, state}

  def handle_call({:summary, id}, _from, %{session: %{id: id, save: false}} = state),
    do: {:reply, {:ok, state.log.summary}, state}

  def handle_call({:summary, _id}, _from, state), do: {:reply, :saved, state}

  def handle_call({:kept_traces, id}, _from, %{session: %{id: id, save: false}} = state),
    do: {:reply, {:ok, state.log.traces}, state}

  def handle_call({:kept_traces, _id}, _from, state), do: {:reply, {:error, :not_found}, state}

  @impl true
  def handle_cast(:disconnecting, %{session: %{status: :running}} = state),
    do: {:noreply, put_stop_request(state, :disconnected, nil)}

  def handle_cast(:disconnecting, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, agent_dropped},
        %{session: %{tracer: tracer, status: :running} = session, run: run} = state
      ) do
    {entries, session, run} =
      Run.absorb(run, session, events, agent_dropped, overloaded?(session))

    state = append(%{state | session: session, run: run}, entries)
    {:noreply, stop_over_limit(state)}
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: agent_dropped}},
        %{session: %{tracer: tracer, status: :running}, run: run} = state
      ) do
    {:noreply, end_run(state, reason, Run.total_dropped(run, agent_dropped))}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    {:noreply, end_run(state, down_reason(reason), session.dropped)}
  end

  def handle_info({:trace_written, id, bytes}, %{session: %{id: id} = session} = state),
    do: {:noreply, stop_over_limit(%{state | session: %{session | bytes: bytes}})}

  def handle_info({:trace_write_failed, id, _reason}, %{session: %{id: id}} = state),
    do: {:noreply, request_stop(state, :write_failed)}

  def handle_info(_stale, state), do: {:noreply, state}

  defp startable(nil), do: {:error, :no_session}
  defp startable(%Session{config: nil}), do: {:error, :not_configured}
  defp startable(%Session{status: :running}), do: {:error, :busy}
  defp startable(%Session{} = session), do: {:ok, session}

  defp resolve_pids(_node, %Config{processes: processes}) when processes != :pids, do: {:ok, []}

  defp resolve_pids(node, config), do: Voyager.Pid.resolve_all(node, config.pids)

  defp start_failed(reason, origin) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: origin, reason: reason}
    )

    {:error, reason}
  end

  defp stop_tracer(node, tracer),
    do: Agent.call(node, :trace_stop, [tracer], Agent.default_timeout())

  defp validate_entries_opt!(:order, order) when order in [:asc, :desc], do: :ok
  defp validate_entries_opt!(:limit, limit) when is_integer(limit) and limit >= 1, do: :ok

  defp validate_entries_opt!(key, seq)
       when key in [:since, :before] and is_integer(seq) and seq >= 0,
       do: :ok

  defp validate_entries_opt!(key, value),
    do: raise(ArgumentError, "invalid #{inspect(key)} option: #{inspect(value)}")

  defp new_session(origin, save) do
    id = new_session_id(origin, save)

    %Session{
      id: id,
      origin: origin,
      save: save,
      created_at: DateTime.utc_now(),
      storage_limit: storage_limit(id)
    }
  end

  defp new_session_id(origin, true) do
    {:ok, row} = TraceSessionActions.create(%{origin: origin, status: :idle})
    row.id
  end

  defp new_session_id(_origin, false), do: -System.unique_integer([:positive])

  defp with_saved(id, fun) do
    Writer.flush()

    case TraceSessionQueries.get(id) do
      nil -> {:error, :not_found}
      row -> fun.(row)
    end
  end

  defp saved_session(row) do
    Session.from_row(
      row,
      TraceEntryQueries.controls(row.id),
      TraceEntryQueries.traces_before_last_run(row.id),
      TraceEntryQueries.next_seq(row.id),
      storage_limit(row.id)
    )
  end

  defp activate(session) do
    broadcast({:session_activated, session})
    broadcast_session(session)
    {:reply, {:ok, session}, %__MODULE__{session: session}}
  end

  defp start_tracer(session, spec, limits) do
    with {:ok, reply} <-
           Agent.call(session.node, :trace_start, [self(), spec, limits], Agent.default_timeout()),
         do: reply
  end

  defp begin_run(%{session: session} = state, tracer, origin) do
    Process.monitor(tracer)
    session = Session.running(session, tracer, storage_limit(session.id))
    emit_started(session, origin)

    append(%{state | session: session, run: Run.new(session, origin)}, [Entry.started(origin)])
  end

  @spec end_run(state(), stop_reason(), non_neg_integer()) :: state()
  defp end_run(%{run: run} = state, reason, dropped) do
    {reason, origin} = run.stop_request || {reason, nil}
    session = Session.stopped(state.session, reason, dropped)
    run_traces = session.traces - session.run_traces_before
    run_dropped = session.dropped - run.dropped_before
    emit_stopped(run, reason, run_traces, run_dropped)

    %{state | session: session, run: nil}
    |> append(
      Entry.dropped(session.dropped - run.dropped_logged) ++
        [Entry.stopped(origin, reason, run_traces, run_dropped)]
    )
  end

  defp emit_started(session, origin) do
    Voyager.Telemetry.dispatch!("voyager.trace.start",
      metadata:
        session.config
        |> Map.take([:capture, :scope, :return_trace, :processes])
        |> Map.put(:origin, origin)
    )
  end

  defp emit_stopped(run, reason, traces, dropped) do
    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: traces,
        dropped: dropped,
        duration_ms: System.monotonic_time(:millisecond) - run.started_ms
      },
      metadata: %{origin: run.origin, reason: reason}
    )
  end

  defp stop_over_limit(%{session: session} = state) when session.bytes > session.storage_limit,
    do: request_stop(state, :storage_limit)

  defp stop_over_limit(state), do: state

  defp request_stop(%{session: session, run: %Run{stop_request: nil}} = state, reason) do
    Task.Supervisor.start_child(Voyager.TaskSupervisor, fn ->
      stop_tracer(session.node, session.tracer)
    end)

    put_stop_request(state, reason, nil)
  end

  defp request_stop(state, _reason), do: state

  defp put_stop_request(%{run: run} = state, reason, origin),
    do: %{state | run: %{run | stop_request: {reason, origin}}}

  defp storage_limit(id) do
    max(storage_limit_mb() * 1_000_000 - TraceSessionQueries.bytes_except(id), 0)
  end

  defp down_reason(:noconnection), do: :node_down
  defp down_reason(reason), do: {:tracer_down, reason}

  # Batches are dropped here too, so a flood cannot grow this process' mailbox either.
  defp overloaded?(session) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox or (session.save and Writer.overloaded?())
  end

  @spec append(state(), [Entry.unnumbered()]) :: state()
  defp append(state, []), do: state

  defp append(%__MODULE__{session: session} = state, entries) do
    {entries, log} = MemoryLog.append(state.log, entries, session.seq)
    session = %{session | seq: session.seq + length(entries)}

    if session.save, do: Writer.append(session, entries)
    broadcast({:session_entries, session, entries})
    broadcast_session(session)

    %{state | session: session, log: log}
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)

  defp broadcast_session(session),
    do: Phoenix.PubSub.broadcast(Voyager.PubSub, @session_topic, {:session_updated, session})
end
