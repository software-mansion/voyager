defmodule Voyager.Services.Tracer.Writer do
  @moduledoc """
  Saves the entries of a saved `Voyager.Services.Tracer` session, so encoding and
  database writes never run in the Tracer's mailbox. Appends are coalesced into one
  transaction per flush interval. After each flush the Tracer gets
  `{:trace_written, session_id, bytes}`, or `{:trace_write_failed, session_id, reason}`
  when the entries were dropped.
  """

  use GenServer

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Repo
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session

  require Logger

  @flush_ms 200
  # 500 rows of ~14 columns stay far below SQLite's bound-variable limit.
  @chunk_rows 500
  @flush_rows 2_000
  @max_pending 10_000
  @pending_key {__MODULE__, :pending}

  defstruct [:counter, pending: [], count: 0, session: nil, timer: nil]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Queues numbered `entries`; `session` is its state after them."
  @spec append(Session.t(), [Tracer.entry()]) :: :ok
  def append(session, entries) do
    :counters.add(:persistent_term.get(@pending_key), 1, length(entries))
    GenServer.cast(__MODULE__, {:append, session, entries})
  end

  @doc "Flushes what is queued, then prunes older sessions over the storage limit."
  @spec close_run(Session.t()) :: :ok
  def close_run(session), do: GenServer.cast(__MODULE__, {:close_run, session})

  @doc "Blocks until everything appended so far is in the database."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "True while too many entries wait to be saved, so the caller sheds instead of queueing more."
  @spec overloaded?() :: boolean()
  def overloaded? do
    case :persistent_term.get(@pending_key, nil) do
      nil -> false
      counter -> :counters.get(counter, 1) > @max_pending
    end
  end

  @impl true
  def init(nil) do
    counter = :counters.new(1, [:atomics])
    :persistent_term.put(@pending_key, counter)
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{counter: counter}}
  end

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  @impl true
  def handle_cast({:append, session, entries}, state) do
    state = if state.session && state.session.id != session.id, do: flush(state), else: state
    state = %{state | session: session, pending: [entries | state.pending]}
    state = %{state | count: state.count + length(entries)}

    if state.count >= @flush_rows,
      do: {:noreply, flush(state)},
      else: {:noreply, schedule_flush(state)}
  end

  def handle_cast({:close_run, session}, state) do
    state = flush(%{state | session: session})

    with {:error, reason} <-
           guarded(fn -> TraceSessionActions.prune(session.storage_limit, session.id) end) do
      Logger.error("Pruning trace sessions failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp schedule_flush(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_ms)}

  defp schedule_flush(state), do: state

  defp flush(%{pending: []} = state), do: state

  defp flush(%{session: session, pending: pending} = state) do
    entries = pending |> Enum.reverse() |> Enum.concat()

    case guarded(fn -> write(session, entries) end) do
      {:ok, bytes} ->
        notify({:trace_written, session.id, bytes})

      {:error, reason} ->
        Logger.error("Saving trace session #{session.id} failed: #{inspect(reason)}")
        notify({:trace_write_failed, session.id, reason})
    end

    :counters.sub(state.counter, 1, length(entries))
    %{state | pending: [], count: 0}
  end

  # The Tracer is already stopped when the Writer drains on shutdown.
  defp notify(message) do
    if pid = Process.whereis(Tracer), do: send(pid, message)
  end

  defp write(session, entries) do
    {:ok, bytes} =
      Repo.transact(fn ->
        stored =
          entries
          |> Enum.chunk_every(@chunk_rows)
          |> prepared_chunks(session.id)
          |> Enum.map(&TraceEntryActions.insert_prepared/1)
          |> Enum.sum()

        {:ok, TraceSessionActions.sync(session, stored)}
      end)

    bytes
  end

  # Encoding is most of the CPU cost and the insert stays serial, so rows are built ahead in parallel.
  defp prepared_chunks(chunks, session_id) do
    Voyager.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      chunks,
      &TraceEntryActions.prepare(session_id, &1),
      max_concurrency: max(div(System.schedulers_online(), 2), 1),
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, prepared} -> prepared
      {:exit, reason} -> exit(reason)
    end)
  end

  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
