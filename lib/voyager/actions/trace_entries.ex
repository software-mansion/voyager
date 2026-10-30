defmodule Voyager.Actions.TraceEntries do
  @moduledoc """
  Writes `Voyager.Services.Tracer` log entries of a saved session: `:trace` entries
  as `Voyager.Schemas.TraceEvent` rows, the rest as `Voyager.Schemas.TraceSessionEvent` rows.
  """

  alias Voyager.Repo
  alias Voyager.Schemas.TraceEvent
  alias Voyager.Schemas.TraceSessionEvent
  alias Voyager.StoredTerm

  # Measured on SQLite: id, session_id, seq, `at` as ISO text, kind, flags and the seq index.
  @row_overhead_bytes 64

  @blank_session_event Map.new(TraceSessionEvent.__schema__(:fields) -- [:id], &{&1, nil})

  @type prepared :: %{trace: [map()], session: [map()]}

  @doc """
  Inserts the entries. A trace's `search_text` has its terms inspected, with pids
  in the traced node's `<0.X.Y>` form. Returns the bytes stored plus a fixed cost per row.
  """
  @spec insert_all(integer(), [map()]) :: non_neg_integer()
  def insert_all(session_id, entries),
    do: session_id |> prepare(entries) |> insert_prepared()

  @doc "Encodes the entries into rows without touching the database, so it can run in parallel."
  @spec prepare(integer(), [map()]) :: prepared()
  def prepare(session_id, entries) do
    {traces, session_events} = Enum.split_with(entries, &(&1.kind == :trace))

    %{
      trace: Enum.map(traces, &trace_row(session_id, &1)),
      session: Enum.map(session_events, &session_event_row(session_id, &1))
    }
  end

  @doc "Inserts rows from `prepare/2`; returns what `insert_all/2` does."
  @spec insert_prepared(prepared()) :: non_neg_integer()
  def insert_prepared(%{trace: traces, session: session_events}),
    do: insert(TraceEvent, traces) + insert(TraceSessionEvent, session_events)

  defp insert(_schema, []), do: 0

  defp insert(schema, rows) do
    Repo.insert_all(schema, rows)
    rows |> Enum.map(&row_bytes/1) |> Enum.sum()
  end

  defp session_event_row(session_id, entry) do
    @blank_session_event
    |> Map.merge(base(session_id, entry))
    |> Map.put(:kind, entry.kind)
    |> Map.merge(session_event_fields(entry))
  end

  defp session_event_fields(%{kind: :configured} = entry) do
    %{
      origin: entry.origin,
      node: Atom.to_string(entry.node),
      config: Map.from_struct(entry.config)
    }
  end

  defp session_event_fields(%{kind: :started} = entry), do: %{origin: entry.origin}

  defp session_event_fields(%{kind: :stopped} = entry) do
    %{
      origin: entry.origin,
      reason: StoredTerm.encode(entry.reason),
      traces: entry.traces,
      dropped: entry.dropped
    }
  end

  defp session_event_fields(%{kind: :dropped} = entry), do: %{dropped: entry.count}

  defp trace_row(session_id, %{mfa: {m, f, a}} = entry) do
    Map.merge(base(session_id, entry), %{
      type: entry.type,
      pid: StoredTerm.encode(entry.pid),
      process: StoredTerm.encode(entry.process),
      module: Atom.to_string(m),
      function: Atom.to_string(f),
      arity: a,
      args: if(Map.has_key?(entry, :args), do: StoredTerm.encode(entry.args)),
      value: if(Map.has_key?(entry, :value), do: StoredTerm.encode(entry.value)),
      truncated: entry[:truncated],
      duration_us: entry[:duration_us],
      search_text: search_text(entry)
    })
  end

  defp search_text(%{mfa: {m, f, a}} = entry) do
    terms = for key <- [:args, :value], Map.has_key?(entry, key), do: inspect_term(entry[key])

    Enum.join(
      [
        inspect_term(entry.pid),
        inspect_term(entry.process),
        Exception.format_mfa(m, f, a) | terms
      ],
      " "
    )
  end

  defp base(session_id, entry),
    do: %{session_id: session_id, seq: entry.seq, at: DateTime.from_unix!(entry.at, :microsecond)}

  defp inspect_term(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, inspect_fun: &inspect_pid/2)

  defp inspect_pid(pid, _opts) when is_pid(pid), do: "#PID" <> Voyager.Pid.format(pid, :local)
  defp inspect_pid(term, opts), do: Inspect.inspect(term, opts)

  defp row_bytes(row) do
    row
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(@row_overhead_bytes + config_bytes(row), &(byte_size(&1) + &2))
  end

  defp config_bytes(%{config: config}) when is_map(config), do: :erlang.external_size(config)
  defp config_bytes(_row), do: 0
end
