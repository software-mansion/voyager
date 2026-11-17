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
  alias Voyager.Services.TermSyntax
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
  Up to `:limit` trace entries whose `syntax` line of `search_text` contains `query`, ignoring
  ASCII case, with `seq` below `:before`, newest first, and the `total` of matches in the
  session, nil once `:before` is given.
  """
  @spec search(integer(), String.t(), TermSyntax.syntax(), keyword()) ::
          %{entries: [map()], total: non_neg_integer() | nil}
  def search(session_id, query, syntax, opts) do
    escaped = String.replace(query, ["\\", "%", "_"], &("\\" <> &1))
    # `search_text` holds one newline, between its Elixir and Erlang lines.
    pattern = if syntax == :erlang, do: "%\n%#{escaped}%", else: "%#{escaped}%\n%"

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
    # A session never started has a NULL `max`, which no `seq` is below.
    from(e in TraceEvent,
      where: e.session_id == ^session_id and e.seq < subquery(last_start(session_id))
    )
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

  @doc "Buckets a saved session's trace timestamps in SQLite into its `Overview.activity`."
  @spec activity(integer(), [Overview.run()], DateTime.t()) :: Overview.activity() | nil
  def activity(session_id, runs, now \\ DateTime.utc_now())
  def activity(_session_id, [], _now), do: nil

  def activity(session_id, runs, now) do
    if List.last(runs).reason == :running,
      do: live_activity(session_id, now),
      else: full_activity(session_id, runs)
  end

  @doc "The trace count and latest `at` of a run that has no stop entry."
  @spec open_run_extent(integer(), Overview.run()) :: {non_neg_integer(), DateTime.t() | nil}
  def open_run_extent(session_id, run) do
    session_id
    |> run_events(run)
    |> select([e], {count(e.id), max(e.at)})
    |> Repo.one()
  end

  defp live_activity(session_id, now) do
    bucket_us = Overview.live_bucket_ms() * 1_000
    {first, last} = Overview.live_window(now)
    first_dt = DateTime.from_unix!(first * bucket_us, :microsecond)
    end_dt = DateTime.from_unix!((last + 1) * bucket_us, :microsecond)

    counts =
      TraceEvent
      |> where([e], e.session_id == ^session_id and e.at >= ^first_dt and e.at < ^end_dt)
      |> query_buckets(0, bucket_us)

    Overview.live_activity(first, last, counts)
  end

  defp full_activity(session_id, runs) do
    max_ats =
      for %{stopped_at: nil} = run <- runs,
          max_at = max_run_at(session_id, run),
          not is_nil(max_at),
          into: %{},
          do: {run.index, DateTime.to_unix(max_at, :microsecond)}

    {spans, bucket_ms} = Overview.plan_segments(runs, max_ats)
    bucket_us = bucket_ms * 1_000

    run_buckets =
      for {run, {start_us, _end_us}} <- Enum.zip(runs, spans),
          buckets = run_events(session_id, run) |> query_buckets(start_us, bucket_us),
          map_size(buckets) > 0,
          into: %{},
          do: {run.index, buckets}

    Overview.build_segments(runs, spans, bucket_ms, run_buckets)
  end

  defp max_run_at(session_id, run) do
    session_id
    |> run_events(run)
    |> select([e], max(e.at))
    |> Repo.one()
  end

  defp run_events(session_id, run) do
    TraceEvent
    |> where([e], e.session_id == ^session_id)
    |> where(^in_run_seq(run))
  end

  # `ecto_sqlite3` dumps `:utc_datetime_usec` as `YYYY-MM-DDTHH:MM:SS.ffffffZ`; `substr(..., 21, 6)` is `ffffff`.
  defp query_buckets(query, start_us, bucket_us) do
    query
    |> select([e], %{
      bucket:
        selected_as(
          fragment(
            "max((CAST(unixepoch(?) AS INTEGER) * 1000000 + CAST(substr(?, 21, 6) AS INTEGER)) - ?, 0) / ?",
            e.at,
            e.at,
            ^start_us,
            ^bucket_us
          ),
          :bucket
        ),
      count: count(e.id)
    })
    |> group_by(selected_as(:bucket))
    |> Repo.all()
    |> Map.new(&{&1.bucket, &1.count})
  end

  defp in_run_seq(%{seq: seq, next_seq: nil}), do: dynamic([e], e.seq > ^seq)

  defp in_run_seq(%{seq: seq, next_seq: next_seq}),
    do: dynamic([e], e.seq > ^seq and e.seq < ^next_seq)

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
