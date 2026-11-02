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
  `{:session_activated, session}`, `{:session_closed, id}` and
  `{:session_entries, session, entries}` with the entries just appended, oldest first.

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
  alias Voyager.Services.Tracer.Run
  alias Voyager.Services.Tracer.Session
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Settings

  @topic "tracing"
  @kept_traces 500
  @max_mailbox 1_000
  # Returns that never come would grow the open calls forever, so they reset past this.
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
          | :write_failed
          | :interrupted
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
  defstruct session: nil, run: nil, controls: [], traces: []

  @typep state :: %__MODULE__{
           session: Session.t() | nil,
           run: Run.t() | nil,
           controls: [entry()],
           traces: [entry()]
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
  def stop(origin) when origin in [:ui, :mcp] do
    with {:ok, node, tracer} <- GenServer.call(__MODULE__, {:stop, origin}) do
      Agent.call(node, :trace_stop, [tracer], Agent.default_timeout())
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
          {:ok, %{entries: [entry()], truncated?: boolean()}} | {:error, :not_found}
  def entries(id, opts \\ []) do
    opts = Keyword.validate!(opts, [:since, :before, order: :desc, limit: 100])
    Enum.each(opts, fn {key, value} -> validate_entries_opt!(key, value) end)

    case GenServer.call(__MODULE__, {:entries, id, opts}) do
      :saved -> saved_entries(id, opts)
      reply -> reply
    end
  end

  @impl true
  def init(nil), do: {:ok, %__MODULE__{}, {:continue, :interrupt_running}}

  @impl true
  def handle_continue(:interrupt_running, state) do
    Writer.flush()
    TraceSessionActions.interrupt_running()
    {:noreply, state}
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
      storage_limit: storage_limit(id)
    }

    broadcast({:session_activated, session})
    {:reply, {:ok, session}, %__MODULE__{session: session}}
  end

  def handle_call({:load, id}, _from, state) do
    Writer.flush()
    TraceSessionActions.interrupt_running()

    case TraceSessionQueries.get(id) do
      nil -> {:reply, {:error, :not_found}, state}
      row -> loaded(row)
    end
  end

  def handle_call({:delete, id}, _from, %{session: %{id: id, status: :running}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:delete, id}, _from, %{session: %{id: id, save: true}}) do
    Writer.flush()
    broadcast({:session_closed, id})
    {:reply, TraceSessionActions.delete(id), %__MODULE__{}}
  end

  def handle_call({:delete, id}, _from, state) do
    Writer.flush()
    {:reply, TraceSessionActions.delete(id), state}
  end

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
            stopped_at: nil,
            storage_limit: storage_limit(session.id)
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
          dropped_logged: session.dropped,
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
    {:reply, {:ok, session.node, session.tracer},
     %{state | run: %{state.run | stop_request: {:stopped, origin}}}}
  end

  def handle_call({:stop, _origin}, _from, state), do: {:reply, :ok, state}

  def handle_call(:active, _from, state), do: {:reply, state.session, state}

  def handle_call(
        {:entries, id, opts},
        _from,
        %{session: %{id: id, save: false} = session} = state
      ) do
    since = Keyword.get(opts, :since, 0)
    before = min(Keyword.get(opts, :before, session.seq), session.seq)
    order = opts[:order]

    page =
      (state.controls ++ state.traces)
      |> Enum.filter(&(&1.seq >= since and &1.seq < before))
      |> Enum.sort_by(& &1.seq, order)
      |> Enum.take(opts[:limit])

    # Seqs have no gaps, so a seq in the covered range without an entry was evicted.
    # A full page covers the range up to its last entry; a short one the whole range.
    covered =
      case {order, length(page) == opts[:limit]} do
        {:asc, true} -> since..List.last(page).seq//1
        {:desc, true} -> List.last(page).seq..(before - 1)//1
        _short -> since..(before - 1)//1
      end

    {:reply, {:ok, %{entries: page, truncated?: length(page) < Range.size(covered)}}, state}
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
    shedding? = overloaded?(session)

    {events, shed} =
      if shedding?,
        do: {[], run.shed + length(events)},
        else: {events, run.shed}

    dropped = run.dropped_before + agent_dropped + shed

    {open_calls, open_count} =
      if dropped > session.dropped, do: {%{}, 0}, else: {run.open_calls, run.open_count}

    {events, open_calls, open_count} =
      if session.config.return_trace,
        do: pair_returns(events, open_calls, open_count),
        else: {events, open_calls, open_count}

    session = %{session | traces: session.traces + length(events), dropped: dropped}

    # While shedding, drops are only counted: a marker per batch would queue on the overloaded Writer.
    {dropped_entries, dropped_logged} =
      if shedding?,
        do: {[], run.dropped_logged},
        else: {dropped_entry(dropped - run.dropped_logged), dropped}

    run = %{
      run
      | shed: shed,
        open_calls: open_calls,
        open_count: open_count,
        dropped_logged: dropped_logged
    }

    state = %{state | session: session, run: run}

    entries = dropped_entries ++ Enum.map(events, &Map.put(&1, :kind, :trace))
    state = if entries == [], do: state, else: append(state, entries)

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

  def handle_info({:trace_written, id, bytes}, %{session: %{id: id} = session} = state),
    do: {:noreply, stop_over_limit(%{state | session: %{session | bytes: bytes}})}

  def handle_info({:trace_write_failed, id, _reason}, %{session: %{id: id}} = state),
    do: {:noreply, request_stop(state, :write_failed)}

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
        dropped_entry(session.dropped - run.dropped_logged) ++
          [entry(:stopped, origin, reason: reason, traces: run_traces, dropped: run_dropped)]
      )

    state
  end

  defp stop_over_limit(%{session: session} = state) when session.bytes > session.storage_limit,
    do: request_stop(state, :storage_limit)

  defp stop_over_limit(state), do: state

  defp request_stop(%{session: session, run: %Run{stop_request: nil} = run} = state, reason) do
    Task.Supervisor.start_child(Voyager.TaskSupervisor, fn ->
      Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    end)

    %{state | run: %{run | stop_request: {reason, nil}}}
  end

  defp request_stop(state, _reason), do: state

  defp storage_limit(id) do
    limit = Settings.get(:trace_storage_limit_mb, @default_storage_limit_mb) * 1_000_000
    max(limit - TraceSessionQueries.bytes_except(id), 0)
  end

  defp pair_returns(events, open_calls, open_count) do
    {open_calls, open_count} =
      if open_count > @max_open_calls, do: {%{}, 0}, else: {open_calls, open_count}

    {events, {open_calls, open_count}} =
      Enum.map_reduce(events, {open_calls, open_count}, &pair_return/2)

    {events, open_calls, open_count}
  end

  defp pair_return(%{type: :call} = event, {open_calls, open_count}) do
    open_calls = Map.update(open_calls, {event.pid, event.mfa}, [event.at], &[event.at | &1])
    {event, {open_calls, open_count + 1}}
  end

  defp pair_return(event, {open_calls, open_count}) do
    key = {event.pid, event.mfa}

    case open_calls do
      %{^key => [at | rest]} ->
        open_calls =
          if rest == [], do: Map.delete(open_calls, key), else: Map.put(open_calls, key, rest)

        {Map.put(event, :duration_us, event.at - at), {open_calls, open_count - 1}}

      _no_call ->
        {event, {open_calls, open_count}}
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
      storage_limit: storage_limit(row.id),
      seq: TraceEntryQueries.next_seq(row.id),
      started_at: row.started_at,
      stopped_at: row.stopped_at
    }

    broadcast({:session_activated, session})

    state = %__MODULE__{
      session: session,
      controls: controls,
      traces: TraceEntryQueries.traces(row.id, @kept_traces)
    }

    {:reply, {:ok, session}, state}
  end

  defp saved_entries(id, opts) do
    Writer.flush()

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

  defp validate_entries_opt!(:order, order) when order in [:asc, :desc], do: :ok
  defp validate_entries_opt!(:limit, limit) when is_integer(limit) and limit >= 1, do: :ok

  defp validate_entries_opt!(key, seq)
       when key in [:since, :before] and is_integer(seq) and seq >= 0,
       do: :ok

  defp validate_entries_opt!(key, value),
    do: raise(ArgumentError, "invalid #{inspect(key)} option: #{inspect(value)}")

  defp dropped_entry(0), do: []
  defp dropped_entry(count), do: [entry(:dropped, nil, count: count)]

  # Dropped entries come with every shed batch, so they are capped with the traces.
  @spec append(state(), [entry()]) :: state()
  defp append(%__MODULE__{session: session} = state, entries) do
    entries = Enum.with_index(entries, &Map.put(&1, :seq, session.seq + &2))
    session = %{session | seq: session.seq + length(entries)}

    {traces, controls} =
      Enum.split_with(entries, &(&1.kind in [:trace, :dropped]))

    if session.save and entries != [], do: Writer.append(session, entries)
    broadcast({:session_entries, session, entries})

    kept = Enum.take(Enum.reverse(traces) ++ state.traces, @kept_traces)

    %{
      state
      | session: session,
        controls: Enum.reverse(controls) ++ state.controls,
        traces: kept
    }
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
  defp overloaded?(session) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox or (session.save and Writer.overloaded?())
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)
end
