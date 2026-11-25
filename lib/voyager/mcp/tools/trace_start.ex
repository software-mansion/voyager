defmodule Voyager.MCP.Tools.TraceStart do
  @moduledoc """
  Starts the tracing session set up in Voyager, or resumes it once stopped; a
  resumed session keeps its events and counts and gets fresh limits. With
  `session_id`, starts that session instead: a saved one from `trace_history` is
  loaded first and runs again, which discards an unsaved active session (the result
  says so). Returns the session's report right away: status, runs, summary and a
  sample of the newest events. Call `trace_watch` to wait for it to end,
  `trace_history` to read its events while it runs, or `trace_stop` to end it early.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.Remote
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session

  schema do
    field :session_id, :integer,
      description:
        "Session to start, e.g. a saved one from `trace_history`. Defaults to the active one."
  end

  @impl true
  def execute(params, frame) do
    reply =
      case start(params[:session_id]) do
        {:ok, session, notes} -> TraceReport.reply(session, notes)
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, reply, frame}
  end

  @doc """
  Starts session `id`, or the active one when nil, on the node Voyager is connected to.
  `notes` holds `discarded` when an unsaved active session was replaced to load it.
  """
  @spec start(integer() | nil) :: {:ok, Session.t(), map()} | {:error, String.t()}
  def start(id) do
    with {:ok, session} <- find(id),
         {:ok, session} <- startable(session, NodeSession.current()),
         {:ok, session, notes} <- activate(session.id),
         {:ok, session} <- run(session) do
      {:ok, session, notes}
    end
  end

  defp find(nil) do
    case Tracer.active() do
      nil -> {:error, TraceReport.no_session()}
      session -> {:ok, session}
    end
  end

  defp find(id) do
    case Tracer.session(id) do
      {:ok, session, _where} -> {:ok, session}
      {:error, :not_found} -> {:error, "No tracing session #{id}"}
    end
  end

  defp startable(%{config: nil}, _node_session),
    do: {:error, "The tracing session has no function to trace yet, call `trace_configure`"}

  defp startable(%{status: :running}, _node_session), do: {:error, TraceReport.start_error(:busy)}
  defp startable(_session, nil), do: {:error, Remote.not_connected()}
  defp startable(%{node: node} = session, %{node: node}), do: {:ok, session}

  defp startable(session, node_session),
    do: {:error, TraceReport.other_node(session.node, node_session.node)}

  @doc """
  Makes session `id` the active one, loading it when saved. `notes` holds `discarded`
  when that replaced an unsaved active session with events.
  """
  @spec activate(integer()) :: {:ok, Session.t(), map()} | {:error, String.t()}
  def activate(id) do
    case Tracer.active() do
      %{id: ^id} = session -> {:ok, session, %{}}
      active -> load(id, discarded(active))
    end
  end

  defp load(id, notes) do
    case Tracer.load(id) do
      {:ok, session} -> {:ok, session, notes}
      {:error, :busy} -> {:error, "Another tracing session is running, call `trace_stop` first"}
      {:error, :not_found} -> {:error, "No saved tracing session #{id}"}
    end
  end

  defp discarded(%{save: false, traces: traces} = active) when traces > 0,
    do: %{discarded: "The unsaved session #{active.id} and its #{traces} events were discarded"}

  defp discarded(_active), do: %{}

  defp run(%{id: id}) do
    case Tracer.start(:mcp, id) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, TraceReport.start_error(reason)}
    end
  end
end
