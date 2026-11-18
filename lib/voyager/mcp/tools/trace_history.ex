defmodule Voyager.MCP.Tools.TraceHistory do
  @moduledoc """
  Without `session_id`, lists the active tracing session and the newest saved ones,
  optionally only those on `node`. Pass the returned `next_before_id` as `before_id`
  for older ones.

  With `session_id`, returns that session's status, its runs (a run's `config` lists only
  the settings that differ from the session's current ones), its summary (and, after
  several runs, `last_run_summary`) and a page of its events, oldest first, from `since`
  (a `seq`, 0 by default). Pass the returned `next_since` to read the next page; `more`
  says the page was full. This works on a running session too, to follow it in batches.
  An unsaved session keeps only its newest events, and `truncated` marks a page missing
  evicted ones; its summary still counts every event.

  With `session_id` and `query`, returns the trace events containing `query` (in the pid,
  process, function, arguments or value, ignoring case) instead, newest first, with
  `total_matches`. Pass the returned `next_before` as `before` for older matches. Prefer
  this over paging to find a value. An unsaved session searches only its newest events.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer

  @listed 20

  schema do
    field :session_id, :integer, description: "`session_id` of the session to read."

    field :since, :integer,
      min: 0,
      default: 0,
      description: "Read events from this `seq`, e.g. the previous page's `next_since`."

    field :query, :string,
      description: "With `session_id`, search its trace events for this text."

    field :before, :integer,
      min: 0,
      description:
        "With `query`, matches below this `seq`, e.g. the previous result's `next_before`."

    field :limit, :integer, min: 1, max: 200, default: 50, description: "Events per page."

    field :node, :string, description: "Without `session_id`, list only sessions on this node."

    field :before_id, :integer,
      min: 1,
      description: "Without `session_id`, list sessions older than this, e.g. `next_before_id`."
  end

  @impl true
  def execute(%{session_id: id} = params, frame) when is_integer(id) do
    reply =
      with {:ok, session, _where} <- Tracer.session(id),
           {:ok, report} <- read(session, params) do
        Response.json(Response.tool(), report)
      else
        {:error, :not_found} -> Response.error(Response.tool(), "No tracing session #{id}")
      end

    {:reply, reply, frame}
  end

  def execute(params, frame) do
    active = Tracer.active()
    Writer.flush()

    page =
      TraceSessionQueries.page(
        before_id: params[:before_id],
        node: params[:node],
        exclude_id: active && active.id,
        limit: @listed
      )

    pinned =
      if is_nil(params[:before_id]) and on_node?(active, params[:node]), do: [active], else: []

    sessions = Enum.map(pinned ++ page.rows, &TraceReport.header/1)

    result =
      if page.has_more?,
        do: %{sessions: sessions, next_before_id: List.last(page.rows).id},
        else: %{sessions: sessions}

    {:reply, Response.json(Response.tool(), result), frame}
  end

  defp read(session, %{query: query} = params) when is_binary(query) do
    opts = [limit: params.limit] ++ if(params[:before], do: [before: params.before], else: [])

    with {:ok, report} <- TraceReport.search(session, query, opts) do
      oldest = List.first(report.events)

      {:ok,
       Map.merge(report, %{
         next_before: oldest && oldest.seq,
         more: length(report.events) == params.limit
       })}
    end
  end

  defp read(session, params) do
    with {:ok, report} <-
           TraceReport.report(session, since: params.since, order: :asc, limit: params.limit) do
      next_since =
        case List.last(report.events) do
          nil -> params.since
          last -> last.seq + 1
        end

      {:ok,
       Map.merge(report, %{next_since: next_since, more: length(report.events) == params.limit})}
    end
  end

  defp on_node?(nil, _node), do: false
  defp on_node?(_active, nil), do: true
  defp on_node?(%{node: node}, name), do: node != nil and Atom.to_string(node) == name
end
