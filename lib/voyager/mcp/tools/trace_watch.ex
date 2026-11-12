defmodule Voyager.MCP.Tools.TraceWatch do
  @moduledoc """
  Waits until the tracing session ends and returns its report: status and stop
  reason, a summary (calls per function and per process, average rate, slowest
  calls) and a sample of the newest events. Joins a running session, starts one
  that was set up but never run, and returns a stopped session's report at once.

  While it waits the user sees live progress, and other Voyager tool calls wait
  for it to return. Cancelling the call only stops watching: the session keeps
  running. After 10 minutes it stops waiting and returns the report with
  `status` `running`; call it again or `trace_stop`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Frame
  alias Anubis.Server.Notifier
  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.MCP.Tools.TraceStart
  alias Voyager.Services.Tracer

  @max_wait to_timeout(minute: 10)
  @progress_interval 1_000

  schema do
  end

  @doc "How long a call waits for the session to end."
  @spec max_wait() :: pos_integer()
  def max_wait, do: @max_wait

  @impl true
  def execute(_params, frame) do
    # Subscribed before reading the session, so an end in between is not missed.
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
    reply = watch(Tracer.active(), frame)
    Phoenix.PubSub.unsubscribe(Voyager.PubSub, Tracer.session_topic())

    {:reply, reply, frame}
  end

  defp watch(nil, _frame), do: Response.error(Response.tool(), "There is no tracing session")

  defp watch(%{status: :idle} = session, frame) do
    case TraceStart.start(session) do
      {:ok, session} -> await(session, frame)
      {:error, message} -> Response.error(Response.tool(), message)
    end
  end

  defp watch(%{status: :running} = session, frame), do: await(session, frame)

  defp watch(session, _frame), do: TraceReport.reply(session)

  defp await(session, frame) do
    if Frame.progress_token(frame), do: send(self(), :progress)
    deadline = System.monotonic_time(:millisecond) + @max_wait

    case await(session, frame, %{deadline: deadline, reported: -1}) do
      {:ended, session} ->
        TraceReport.reply(session)

      {:waiting, session} ->
        TraceReport.reply(session, %{
          note:
            "Still running after #{div(@max_wait, 60_000)} minutes, call `trace_watch` again or `trace_stop`"
        })

      :closed ->
        Response.error(Response.tool(), "The tracing session was closed")
    end
  end

  defp await(%{id: id} = session, frame, watch) do
    receive do
      {:session_updated, %{id: ^id, status: :running} = session} ->
        await(session, frame, watch)

      {:session_updated, %{id: ^id} = session} ->
        {:ended, session}

      {:session_updated, _closed_or_replaced} ->
        :closed

      :progress ->
        Process.send_after(self(), :progress, @progress_interval)
        await(session, frame, report_progress(session, frame, watch))
    after
      max(watch.deadline - System.monotonic_time(:millisecond), 0) -> {:waiting, session}
    end
  end

  # Progress must increase with each notification, so an idle second sends none.
  defp report_progress(%{traces: traces} = session, frame, %{reported: reported} = watch)
       when traces > reported do
    seconds = DateTime.diff(DateTime.utc_now(), session.run_started_at)
    message = "#{traces} events, #{session.dropped} dropped, #{seconds}s"
    Notifier.progress(frame, Frame.progress_token(frame), traces, message: message)
    %{watch | reported: traces}
  end

  defp report_progress(_session, _frame, watch), do: watch
end
