defmodule Voyager.Actions.TraceEntries do
  @moduledoc """
  Writes `Voyager.Services.Tracer` log entries of a saved session: `:trace` entries
  as `Voyager.Schemas.TraceEvent` rows, the rest as `Voyager.Schemas.TraceSessionEvent` rows.
  """

  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Repo
  alias Voyager.Schemas.TraceEvent
  alias Voyager.Schemas.TraceSessionEvent

  # Measured on SQLite: id, session_id, seq, `at` as ISO text, kind, flags and the seq index.
  @row_overhead_bytes 64

  @blank_session_event Map.new(TraceSessionEvent.__schema__(:fields) -- [:id], &{&1, nil})

  @doc """
  Inserts the entries, with terms inspected and pids in the traced node's
  `<0.X.Y>` form. Returns the bytes stored: the text plus a fixed cost per row.
  """
  @spec insert_all(integer(), [map()]) :: non_neg_integer()
  def insert_all(session_id, entries) do
    {traces, session_events} = Enum.split_with(entries, &(&1.kind == :trace))

    insert(TraceEvent, Enum.map(traces, &trace_row(session_id, &1))) +
      insert(TraceSessionEvent, Enum.map(session_events, &session_event_row(session_id, &1)))
  end

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
      reason: TraceSessionActions.stop_reason_text(entry.reason),
      traces: entry.traces,
      dropped: entry.dropped
    }
  end

  defp session_event_fields(%{kind: :dropped} = entry), do: %{dropped: entry.count}

  defp trace_row(session_id, %{mfa: {m, f, a}} = entry) do
    Map.merge(base(session_id, entry), %{
      type: entry.type,
      pid: Voyager.Pid.format(entry.pid, :local),
      process: if(entry.process != :undefined, do: inspect_term(entry.process)),
      mfa: Exception.format_mfa(m, f, a),
      args: if(Map.has_key?(entry, :args), do: inspect_term(entry.args)),
      value: if(Map.has_key?(entry, :value), do: inspect_term(entry.value)),
      truncated: Map.get(entry, :truncated, false),
      duration_us: Map.get(entry, :duration_us)
    })
  end

  defp base(session_id, entry),
    do: %{session_id: session_id, seq: entry.seq, at: DateTime.from_unix!(entry.at, :microsecond)}

  defp inspect_term(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, inspect_fun: &inspect_pid/2)

  defp inspect_pid(pid, _opts) when is_pid(pid), do: "#PID" <> Voyager.Pid.format(pid, :local)
  defp inspect_pid(term, opts), do: Inspect.inspect(term, opts)

  defp row_bytes(row) do
    row
    |> Map.take([:pid, :process, :mfa, :args, :value, :node, :reason])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(@row_overhead_bytes, &(byte_size(&1) + &2))
  end
end
