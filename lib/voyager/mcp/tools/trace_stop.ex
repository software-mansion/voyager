defmodule Voyager.MCP.Tools.TraceStop do
  @moduledoc """
  Stops the running tracing session, whoever started it, and returns its final
  report: status and stop reason, a summary (calls per function and per process,
  average rate, slowest calls) and a sample of the newest events. A session that
  already stopped returns its report unchanged.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.Services.Tracer

  @stop_timeout Voyager.Agent.default_timeout() + 1_000

  schema do
  end

  @impl true
  def execute(_params, frame) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
    reply = stop(Tracer.active())
    Phoenix.PubSub.unsubscribe(Voyager.PubSub, Tracer.session_topic())

    {:reply, reply, frame}
  end

  defp stop(nil), do: Response.error(Response.tool(), "There is no tracing session")

  defp stop(%{status: :idle}),
    do: Response.error(Response.tool(), "The tracing session has not started, call `trace_start`")

  defp stop(%{status: :running} = session) do
    Tracer.stop(:mcp)
    session |> await_stopped() |> TraceReport.reply()
  end

  defp stop(session), do: TraceReport.reply(session)

  defp await_stopped(%{id: id} = session) do
    receive do
      {:session_updated, %{id: ^id, status: :stopped} = stopped} -> stopped
    after
      @stop_timeout -> session
    end
  end
end
