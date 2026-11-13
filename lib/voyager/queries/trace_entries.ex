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
  alias Voyager.Services.Tracer.Overview
  alias Voyager.Services.Tracer.Summary
  alias Voyager.StoredTerm

  @doc """
  Up to `:limit` entries with `seq` in `[:since, :before)`, `:order` (default `:desc`) by `seq`.
  A `:configured` entry carries the config it replaced as `previous`, nil for the first.
  """
  @spec page(integer(), keyword()) :: [map()]
  def page(session_id, opts) do
    entries =
      merge(
        window(TraceSessionEvent, session_id, opts),
        window(TraceEvent, session_id, opts),
        opts
      )

    if Enum.any?(entries, &(&1.kind == :configured)),
      do: put_previous(entries, configured(session_id)),
      else: entries
  end

  @doc "Every configured, started and stopped entry, newest first."
  @spec controls(integer()) :: [map()]
  def controls(session_id) do
    controls =
      TraceSessionEvent
      |> where([e], e.kind != :dropped)
      |> window(session_id, [])

    put_previous(controls, Enum.filter(controls, &(&1.kind == :configured)))
  end

  @doc """
  Up to `:limit` trace entries containing `query`, ignoring ASCII case, with `seq` below `:before`,
  newest first, and the `total` of matches in the session, nil once `:before` is given.
  """
  @spec search(integer(), String.t(), keyword()) ::
          %{entries: [map()], total: non_neg_integer() | nil}
  def search(session_id, query, opts) do
    pattern = "%" <> String.replace(query, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

    matches =
      from e in TraceEvent,
        where:
          e.session_id == ^session_id and
            fragment("? LIKE ? ESCAPE '\\'", e.search_text, ^pattern)

    total = if opts[:before], do: nil, else: Repo.aggregate(matches, :count)
    %{entries: window(matches, session_id, opts), total: total}
  end

  @doc "How many traces were saved before the session's last `:started` entry; 0 if it never started."
  @spec traces_before_last_run(integer()) :: non_neg_integer()
  def traces_before_last_run(session_id) do
    last_start =
      from s in TraceSessionEvent,
        where: s.session_id == ^session_id and s.kind == :started,
        select: max(s.seq)

    # A session never started has a NULL `max`, which no `seq` is below.
    from(e in TraceEvent, where: e.session_id == ^session_id and e.seq < subquery(last_start))
    |> Repo.aggregate(:count)
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

  @doc "Pairs every trace row of `session_id` with its run `index` and microsecond timestamp."
  @spec trace_timestamps(integer(), [Overview.run()]) :: [{pos_integer(), integer()}]
  def trace_timestamps(_session_id, []), do: []

  def trace_timestamps(session_id, runs) do
    rows =
      from(e in TraceEvent,
        where: e.session_id == ^session_id,
        order_by: [asc: e.seq],
        select: {e.seq, e.at}
      )
      |> Repo.all()

    pair_runs(rows, runs, [])
  end

  defp pair_runs([], _runs, acc), do: Enum.reverse(acc)
  defp pair_runs(_rows, [], acc), do: Enum.reverse(acc)

  defp pair_runs([{seq, _at} | rest], [%{seq: start_seq} | _] = runs, acc)
       when seq <= start_seq do
    pair_runs(rest, runs, acc)
  end

  defp pair_runs(
         [{seq, _at} | _] = rows,
         [%{next_seq: next_seq} | rest_runs],
         acc
       )
       when not is_nil(next_seq) and seq >= next_seq do
    pair_runs(rows, rest_runs, acc)
  end

  defp pair_runs([{_seq, at} | rest], [run | _] = runs, acc) do
    pair_runs(rest, runs, [{run.index, DateTime.to_unix(at, :microsecond)} | acc])
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

  defp configured(session_id) do
    TraceSessionEvent
    |> where(kind: :configured)
    |> window(session_id, [])
  end

  defp put_previous(entries, newest_first) do
    Enum.map(entries, fn
      %{kind: :configured, seq: seq} = entry ->
        previous = Enum.find(newest_first, &(&1.seq < seq))
        Map.put(entry, :previous, previous && previous.config)

      entry ->
        entry
    end)
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
