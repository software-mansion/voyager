defmodule Voyager.MCP.Tools.TraceHistory do
  @moduledoc """
  Without `session_id`, lists the active tracing session and the newest saved ones.

  With `session_id`, returns that session's status and summary and a page of its
  events, oldest first, from `since` (a `seq`, 0 by default). Pass the returned
  `next_since` to read the next page; `more` says the page was full. This works
  on a running session too, to follow it in batches and `trace_stop` it early.
  An unsaved session keeps only its newest events, and `truncated` marks a page
  missing evicted ones; its summary still counts every event.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Writer

  @listed 20

  schema do
    field :session_id, :integer, description: "`session_id` of the session to read."

    field :since, :integer,
      min: 0,
      default: 0,
      description: "Read events from this `seq`, e.g. the previous page's `next_since`."

    field :limit, :integer, min: 1, max: 200, default: 50, description: "Events per page."
  end

  @impl true
  def execute(%{session_id: id} = params, frame) when is_integer(id) do
    reply =
      with {:ok, session} <- session(id),
           {:ok, report} <-
             TraceReport.report(session, since: params.since, order: :asc, limit: params.limit) do
        Response.json(Response.tool(), page(report, params))
      else
        {:error, :not_found} -> Response.error(Response.tool(), "No tracing session #{id}")
      end

    {:reply, reply, frame}
  end

  def execute(_params, frame) do
    active = Tracer.active()
    Writer.flush()

    saved =
      TraceSessionQueries.all()
      |> Enum.reject(&(active && &1.id == active.id))
      |> Enum.take(@listed)
      |> Enum.map(&loaded/1)

    sessions = Enum.map(List.wrap(active) ++ saved, &TraceReport.header/1)
    {:reply, Response.json(Response.tool(), %{sessions: sessions}), frame}
  end

  defp session(id) do
    case Tracer.active() do
      %{id: ^id} = session ->
        {:ok, session}

      _other ->
        Writer.flush()
        if row = TraceSessionQueries.get(id), do: {:ok, loaded(row)}, else: {:error, :not_found}
    end
  end

  defp loaded(row),
    do: %{row | config: row.config && Ecto.embedded_load(Config, row.config, :json)}

  defp page(report, params) do
    next_since =
      case List.last(report.events) do
        nil -> params.since
        last -> last.seq + 1
      end

    Map.merge(report, %{next_since: next_since, more: length(report.events) == params.limit})
  end
end
