defmodule Voyager.MCP.Tools.TraceStart do
  @moduledoc """
  Starts the tracing session set up in Voyager, or resumes it once stopped; a
  resumed session keeps its events and counts and gets fresh limits. Returns the
  session's report right away: status, summary and a sample of the newest events.
  Call `trace_watch` to wait for it to end, `trace_history` to read its events
  while it runs, or `trace_stop` to end it early.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session

  schema do
  end

  @impl true
  def execute(_params, frame) do
    reply =
      case start(Tracer.active()) do
        {:ok, session} -> TraceReport.reply(session)
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, reply, frame}
  end

  @doc "Starts `session`, the active one, on the node Voyager is connected to."
  @spec start(Session.t() | nil) :: {:ok, Session.t()} | {:error, String.t()}
  def start(session) do
    with {:ok, session} <- startable(session, NodeSession.current()), do: run(session)
  end

  defp startable(nil, _node_session), do: {:error, "There is no tracing session"}

  defp startable(%{config: nil}, _node_session),
    do: {:error, "The tracing session has no function to trace yet"}

  defp startable(%{status: :running}, _node_session),
    do: {:error, "The tracing session is already running, call `trace_watch` or `trace_stop`"}

  defp startable(_session, nil),
    do: {:error, "Not connected to any node, call `list_connections` then `connect`"}

  defp startable(%{node: node} = session, %{node: node}), do: {:ok, session}

  defp startable(session, node_session),
    do:
      {:error,
       "The session traces #{session.node} but Voyager is connected to #{node_session.node}"}

  defp run(%{id: id}) do
    case Tracer.start(:mcp) do
      {:ok, %{id: ^id} = session} -> {:ok, session}
      {:ok, _other} -> {:error, "The tracing session changed meanwhile"}
      {:error, :changed} -> {:error, "The tracing session changed meanwhile"}
      {:error, :busy} -> {:error, "The tracing session is already running"}
      {:error, reason} -> {:error, "Could not start tracing: #{inspect(reason)}"}
    end
  end
end
