defmodule Voyager.MCP.Tools.TraceWatch do
  @moduledoc """
  Waits until the tracing session ends and returns its report: status and stop
  reason, a summary (calls per function and per process, average rate, slowest
  calls) and a sample of the newest events. Joins a running session, starts one
  that was set up but never run, and returns a stopped session's report at once.

  While it waits the user sees live progress and the calling agent is blocked, so
  run it in a subagent to keep working; `trace_stop` from elsewhere ends it early.
  Clients older than MCP 2026-07-28 also queue their other Voyager calls behind it.
  Cancelling the call only stops watching: the session keeps running. After 10 minutes it stops waiting and returns the report with
  `status` `running`; call it again or `trace_stop`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Frame
  alias Anubis.Server.Notifier
  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.MCP.Tools.TraceStart
  alias Voyager.Services.Tracer

  @default_max_wait to_timeout(minute: 10)
  @progress_interval 1_000

  schema do
  end

  @spec max_wait() :: pos_integer()
  def max_wait, do: Application.get_env(:voyager, :trace_watch_max_wait_ms, @default_max_wait)

  @impl true
  def execute(_params, frame) do
    # Subscribed before reading the session, so an end in between is not missed.
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
    reply = watch(Tracer.active(), frame)
    Phoenix.PubSub.unsubscribe(Voyager.PubSub, Tracer.session_topic())

    {:reply, reply, frame}
  end

  defp watch(nil, _frame), do: Response.error(Response.tool(), TraceReport.no_session())

  defp watch(%{status: :idle, id: id}, frame) do
    case TraceStart.start(id) do
      {:ok, session, _notes} -> await(session, frame)
      {:error, message} -> join(Tracer.active(), id, message, frame)
    end
  end

  defp watch(%{status: :running} = session, frame), do: await(session, frame)

  defp watch(session, _frame), do: TraceReport.reply(session)

  # Another call, such as a second `trace_watch`, started it first; its run may have ended since.
  defp join(%{id: id, status: status} = session, id, _message, frame) when status != :idle,
    do: watch(session, frame)

  defp join(_active, _id, message, _frame), do: Response.error(Response.tool(), message)

  defp await(session, frame) do
    if Frame.progress_token(frame), do: send(self(), :progress)
    max_wait = max_wait()
    started = System.monotonic_time(:millisecond)
    watch = %{started: started, deadline: started + max_wait, reported: -1, seq: session.seq}

    case await(session, frame, watch) do
      {:ended, session} ->
        TraceReport.reply(session)

      {:waiting, session} ->
        TraceReport.reply(session, %{
          note:
            "Still running after #{div(max_wait, 60_000)} minutes, call `trace_watch` again or `trace_stop`"
        })

      :closed ->
        Response.error(Response.tool(), TraceReport.closed())
    end
  end

  # Updates queued before the watched run started (a configure, the previous run's stop) are older.
  defp await(%{id: id} = session, frame, watch) do
    receive do
      {:session_updated, %{id: ^id, status: :stopped, seq: seq} = stopped} when seq > watch.seq ->
        {:ended, stopped}

      {:session_updated, %{id: ^id, status: :running} = session} ->
        await(session, frame, watch)

      {:session_updated, %{id: ^id}} ->
        await(session, frame, watch)

      {:session_updated, _closed_or_replaced} ->
        if match?(%{id: ^id}, Tracer.active()), do: await(session, frame, watch), else: :closed

      :progress ->
        Process.send_after(self(), :progress, @progress_interval)
        await(session, frame, report_progress(session, frame, watch))
    after
      max(watch.deadline - System.monotonic_time(:millisecond), 0) -> {:waiting, session}
    end
  end

  # Progress must increase with each notification; seconds watched do even on an idle session,
  # so a client that resets its timeout on progress keeps a quiet watch open.
  defp report_progress(session, frame, watch) do
    watched = div(System.monotonic_time(:millisecond) - watch.started, 1_000)

    if watched > watch.reported do
      seconds = DateTime.diff(DateTime.utc_now(), session.run_started_at)
      message = "#{session.traces} events, #{session.dropped} dropped, #{seconds}s"
      Notifier.progress(frame, Frame.progress_token(frame), watched, message: message)
      %{watch | reported: watched}
    else
      watch
    end
  end
end
