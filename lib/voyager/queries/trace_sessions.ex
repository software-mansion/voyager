defmodule Voyager.Queries.TraceSessions do
  @moduledoc "Read queries for tracing sessions."

  import Ecto.Query

  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession
  alias Voyager.Schemas.TraceSessionEvent
  alias Voyager.Services.Tracer.Config

  @default_limit 20

  @type listed :: %{
          id: pos_integer(),
          origin: :ui | :mcp,
          status: :idle | :running | :stopped,
          node: String.t() | nil,
          config: Config.t() | nil,
          stop_reason: Voyager.Services.Tracer.stop_reason() | nil,
          traces: non_neg_integer(),
          dropped: non_neg_integer(),
          bytes: non_neg_integer(),
          runs: non_neg_integer(),
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil
        }

  @spec all() :: [TraceSession.t()]
  def all do
    TraceSession
    |> order_by([s], desc: s.id)
    |> Repo.all()
  end

  @spec get(integer()) :: TraceSession.t() | nil
  def get(id), do: Repo.get(TraceSession, id)

  @spec bytes_except(integer()) :: non_neg_integer()
  def bytes_except(id),
    do: Repo.one(from s in TraceSession, where: s.id != ^id, select: coalesce(sum(s.bytes), 0))

  @doc """
  Newest saved sessions first, cursor-paginated below `:before_id`, optionally narrowed
  to `:node` and omitting `:exclude_id` (e.g. an active session already pinned at the top).
  """
  @spec page(
          before_id: pos_integer(),
          limit: pos_integer(),
          node: String.t() | nil,
          exclude_id: integer() | nil
        ) :: %{rows: [listed()], has_more?: boolean()}
  def page(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    fetched =
      TraceSession
      |> filter_node(opts[:node])
      |> filter_exclude(opts[:exclude_id])
      |> filter_before(opts[:before_id])
      |> order_by([s], desc: s.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    rows = Enum.take(fetched, limit)
    run_counts = run_counts(Enum.map(rows, & &1.id))

    %{
      rows: Enum.map(rows, &to_listed(&1, Map.get(run_counts, &1.id, 0))),
      has_more?: length(fetched) > limit
    }
  end

  @doc "Saved session counts keyed by `node` (configured rows only), omitting `exclude_id`."
  @spec counts_by_node(integer() | nil) :: %{String.t() => non_neg_integer()}
  def counts_by_node(exclude_id \\ nil) do
    TraceSession
    |> where([s], not is_nil(s.node))
    |> filter_exclude(exclude_id)
    |> group_by([s], s.node)
    |> select([s], {s.node, count(s.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Total saved sessions, omitting `exclude_id`."
  @spec total_count(integer() | nil) :: non_neg_integer()
  def total_count(exclude_id \\ nil) do
    TraceSession
    |> filter_exclude(exclude_id)
    |> Repo.aggregate(:count)
  end

  @spec find_listed(pos_integer(), String.t()) :: listed() | nil
  def find_listed(id, node_filter) when is_integer(id) and id > 0 do
    case get(id) do
      nil ->
        nil

      row ->
        if node_filter == "all" or row.node == node_filter do
          runs = Map.get(run_counts([id]), id, 0)
          to_listed(row, runs)
        end
    end
  end

  defp filter_node(query, nil), do: query
  defp filter_node(query, node), do: where(query, [s], s.node == ^node)

  defp filter_exclude(query, id) when is_integer(id) and id > 0,
    do: where(query, [s], s.id != ^id)

  defp filter_exclude(query, _id), do: query

  defp filter_before(query, nil), do: query
  defp filter_before(query, before_id), do: where(query, [s], s.id < ^before_id)

  defp run_counts([]), do: %{}

  defp run_counts(ids) do
    from(e in TraceSessionEvent,
      where: e.session_id in ^ids and e.kind == :started,
      group_by: e.session_id,
      select: {e.session_id, count(e.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp to_listed(%TraceSession{} = row, runs) do
    %{
      id: row.id,
      origin: row.origin,
      status: row.status,
      node: row.node,
      config: row.config && Ecto.embedded_load(Config, row.config, :json),
      stop_reason: row.stop_reason,
      traces: row.traces,
      dropped: row.dropped,
      bytes: row.bytes,
      runs: runs,
      created_at: DateTime.from_naive!(row.inserted_at, "Etc/UTC"),
      started_at: row.started_at,
      stopped_at: row.stopped_at
    }
  end
end
