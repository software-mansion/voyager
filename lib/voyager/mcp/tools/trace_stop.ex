defmodule Voyager.MCP.Tools.TraceStop do
  @moduledoc """
  Stops the running tracing session, whoever started it, and returns its final
  report: status and stop reason, its runs, a summary (calls per function and per
  process, average rate, slowest calls) and a sample of the newest events. A session
  that already stopped returns its report unchanged. With `session_id`, refuses when
  that session is no longer the active one.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.Services.Tracer

  @stop_timeout Voyager.Agent.default_timeout() + 1_000

  schema do
    field :session_id, :integer, description: "Stop only this session, e.g. the one you started."
  end

  @impl true
  def execute(params, frame) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
    reply = stop(Tracer.active(), params[:session_id])
    Phoenix.PubSub.unsubscribe(Voyager.PubSub, Tracer.session_topic())

    {:reply, reply, frame}
  end

  defp stop(nil, _id), do: Response.error(Response.tool(), TraceReport.no_session())

  defp stop(%{id: active}, id) when is_integer(id) and id != active,
    do: Response.error(Response.tool(), "Session #{id} is not active; session #{active} is")

  defp stop(%{status: :idle}, _id),
    do: Response.error(Response.tool(), "The tracing session has not started, call `trace_start`")

  defp stop(%{status: :running} = session, _id) do
    case Tracer.stop(:mcp, session.id) do
      :ok -> await_stopped(session)
      {:error, :changed} -> Response.error(Response.tool(), TraceReport.start_error(:changed))
    end
  end

  defp stop(session, _id), do: TraceReport.reply(session)

  # A stop queued before this run started is older than `seq`.
  defp await_stopped(%{id: id, seq: seq} = session) do
    receive do
      {:session_updated, %{id: ^id, status: :stopped, seq: stopped_seq} = stopped}
      when stopped_seq > seq ->
        TraceReport.reply(stopped)
    after
      @stop_timeout ->
        TraceReport.reply(session, %{
          note: "The node has not confirmed the stop yet, check with `trace_history` or retry"
        })
    end
  end
end
