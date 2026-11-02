defmodule Voyager.Queries.TraceEntries do
  @moduledoc """
  Reads the log of a saved tracing session from its `Voyager.Schemas.TraceSessionEvent`
  and `Voyager.Schemas.TraceEvent` rows, merged by their shared `seq`. Entries come back
  in the `Voyager.Services.Tracer` entry shape, with `at` in microseconds.
  """

  import Ecto.Query
  alias Voyager.Repo
  alias Voyager.Schemas.TraceEvent
  alias Voyager.Schemas.TraceSessionEvent
  alias Voyager.Services.Tracer.Config
  alias Voyager.StoredTerm

  @doc """
  Up to `:limit` entries with `seq` in `[:since, :before)`, `:order` (default `:desc`) by `seq`.
  """
  @spec page(integer(), keyword()) :: [map()]
  def page(session_id, opts) do
    merge(window(TraceSessionEvent, session_id, opts), window(TraceEvent, session_id, opts), opts)
  end

  @doc "Every configured, started and stopped entry, newest first."
  @spec controls(integer()) :: [map()]
  def controls(session_id) do
    TraceSessionEvent
    |> where([e], e.kind != :dropped)
    |> window(session_id, [])
  end

  @doc "The newest `limit` trace and dropped entries, newest first."
  @spec traces(integer(), pos_integer()) :: [map()]
  def traces(session_id, limit) do
    opts = [limit: limit]
    dropped = TraceSessionEvent |> where(kind: :dropped) |> window(session_id, opts)
    merge(dropped, window(TraceEvent, session_id, opts), opts)
  end

  @doc "The `seq` after the session's last entry."
  @spec next_seq(integer()) :: non_neg_integer()
  def next_seq(session_id) do
    [TraceSessionEvent, TraceEvent]
    |> Enum.map(&Repo.one(from e in &1, where: e.session_id == ^session_id, select: max(e.seq)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp window(query, session_id, opts) do
    query
    |> where([e], e.session_id == ^session_id and e.seq >= ^Keyword.get(opts, :since, 0))
    |> where_before(opts[:before])
    |> order_by([e], [{^order(opts), e.seq}])
    |> limit_to(opts[:limit])
    |> Repo.all()
    |> Enum.map(&to_entry/1)
  end

  # Each window already holds its table's first `limit` rows, so the merged first `limit` is exact.
  defp merge(session_events, events, opts) do
    (session_events ++ events)
    |> Enum.sort_by(& &1.seq, order(opts))
    |> Enum.take(Keyword.fetch!(opts, :limit))
  end

  defp order(opts), do: Keyword.get(opts, :order, :desc)

  defp where_before(query, nil), do: query
  defp where_before(query, before), do: where(query, [e], e.seq < ^before)

  defp limit_to(query, nil), do: query
  defp limit_to(query, limit), do: limit(query, ^limit)

  defp to_entry(%TraceEvent{} = row) do
    terms =
      for field <- [:args, :value],
          bin = Map.fetch!(row, field),
          into: %{},
          do: {field, StoredTerm.decode(bin)}

    row
    |> Map.take([:truncated, :duration_us])
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.merge(terms)
    |> Map.merge(%{
      seq: row.seq,
      kind: :trace,
      at: DateTime.to_unix(row.at, :microsecond),
      type: row.type,
      pid: StoredTerm.decode(row.pid),
      process: StoredTerm.decode(row.process),
      mfa: {String.to_atom(row.module), String.to_atom(row.function), row.arity}
    })
  end

  defp to_entry(%TraceSessionEvent{} = row) do
    Map.merge(
      %{seq: row.seq, kind: row.kind, at: DateTime.to_unix(row.at, :microsecond)},
      fields(row)
    )
  end

  defp fields(%{kind: :configured} = row) do
    %{
      origin: row.origin,
      node: String.to_atom(row.node),
      config: Ecto.embedded_load(Config, row.config, :json)
    }
  end

  defp fields(%{kind: :started} = row), do: %{origin: row.origin}

  defp fields(%{kind: :stopped} = row),
    do: %{
      origin: row.origin,
      reason: StoredTerm.decode(row.reason),
      traces: row.traces,
      dropped: row.dropped
    }

  defp fields(%{kind: :dropped} = row), do: %{origin: row.origin, count: row.dropped}
end
