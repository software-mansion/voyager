defmodule Voyager.Services.Tracer.Summary do
  @moduledoc """
  Counts of a session's trace events: calls per function and per process, returns,
  exceptions, and the slowest timed events.

  `functions` maps an mfa to its calls, `processes` a pid to `{process, calls}`.
  Both stop taking new keys at `max_keys/0`, so a session over many short-lived processes
  keeps a bounded summary; `calls` still counts every call.
  """

  alias Voyager.Services.Tracer.Entry

  @max_keys 10_000
  @slowest 5

  defstruct calls: 0, returns: 0, exceptions: 0, functions: %{}, processes: %{}, slowest: []

  @type t :: %__MODULE__{
          calls: non_neg_integer(),
          returns: non_neg_integer(),
          exceptions: non_neg_integer(),
          functions: %{mfa() => pos_integer()},
          processes: %{pid() => {term(), pos_integer()}},
          slowest: [Entry.t()]
        }

  @spec max_keys() :: pos_integer()
  def max_keys, do: @max_keys

  @spec slowest_count() :: pos_integer()
  def slowest_count, do: @slowest

  @doc "Folds the `:trace` entries of `entries` into `summary`; other kinds are skipped."
  @spec add(t(), [Entry.t()]) :: t()
  def add(%__MODULE__{} = summary, entries), do: Enum.reduce(entries, summary, &add_entry/2)

  defp add_entry(%{kind: :trace, type: :call} = entry, summary) do
    %{
      summary
      | calls: summary.calls + 1,
        functions: bump(summary.functions, entry.mfa, &(&1 + 1), 1),
        processes:
          bump(
            summary.processes,
            entry.pid,
            fn {_, n} -> {entry.process, n + 1} end,
            {entry.process, 1}
          )
    }
  end

  defp add_entry(%{kind: :trace, type: type} = entry, summary) do
    summary =
      if type == :exception,
        do: %{summary | exceptions: summary.exceptions + 1},
        else: %{summary | returns: summary.returns + 1}

    track_slowest(summary, entry)
  end

  defp add_entry(_entry, summary), do: summary

  defp bump(counts, key, update, _initial) when is_map_key(counts, key),
    do: Map.update!(counts, key, update)

  defp bump(counts, key, _update, initial) when map_size(counts) < @max_keys,
    do: Map.put(counts, key, initial)

  defp bump(counts, _key, _update, _initial), do: counts

  defp track_slowest(summary, %{duration_us: duration} = entry) when is_integer(duration) do
    slowest =
      [entry | summary.slowest]
      |> Enum.sort_by(& &1.duration_us, :desc)
      |> Enum.take(@slowest)

    %{summary | slowest: slowest}
  end

  defp track_slowest(summary, _entry), do: summary
end
