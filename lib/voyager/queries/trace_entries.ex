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
  alias Voyager.Services.Tracer.Summary
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

  @doc "The `seq` after the session's last entry."
  @spec next_seq(integer()) :: non_neg_integer()
  def next_seq(session_id) do
    [TraceSessionEvent, TraceEvent]
    |> Enum.map(&Repo.one(from e in &1, where: e.session_id == ^session_id, select: max(e.seq)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  @doc "The `Voyager.Services.Tracer.Summary` of the session's trace events."
  @spec summary(integer()) :: Summary.t()
  def summary(session_id) do
    events = where(TraceEvent, [e], e.session_id == ^session_id)

    counts =
      events
      |> group_by([e], e.type)
      |> select([e], {e.type, count(e.id)})
      |> Repo.all()
      |> Map.new()

    %Summary{
      calls: Map.get(counts, :call, 0),
      returns: Map.get(counts, :return, 0),
      exceptions: Map.get(counts, :exception, 0),
      functions: function_calls(events),
      processes: process_calls(events),
      slowest: slowest(events)
    }
  end

  defp function_calls(events) do
    events
    |> where([e], e.type == :call)
    |> group_by([e], [e.module, e.function, e.arity])
    |> order_by([e], desc: count(e.id))
    |> limit(^Summary.max_keys())
    |> select([e], {e.module, e.function, e.arity, count(e.id)})
    |> Repo.all()
    |> Map.new(fn {module, function, arity, calls} ->
      {{String.to_atom(module), String.to_atom(function), arity}, calls}
    end)
  end

  defp process_calls(events) do
    events
    |> where([e], e.type == :call)
    |> group_by([e], e.pid)
    |> order_by([e], desc: count(e.id))
    |> limit(^Summary.max_keys())
    # SQLite takes a bare column from the row holding the max, so this is the latest call's name.
    |> select([e], {e.pid, e.process, max(e.seq), count(e.id)})
    |> Repo.all()
    |> Map.new(fn {pid, process, _seq, calls} ->
      {StoredTerm.decode(pid), {StoredTerm.decode(process), calls}}
    end)
  end

  defp slowest(events) do
    events
    |> where([e], not is_nil(e.duration_us))
    |> order_by([e], desc: e.duration_us)
    |> limit(^Summary.slowest_count())
    |> Repo.all()
    |> Enum.map(&to_entry/1)
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
