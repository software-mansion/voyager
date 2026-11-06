defmodule Voyager.Services.Tracer.MemoryLog do
  @moduledoc """
  An unsaved session's log, kept in memory with only its newest traces and a summary of all of them.
  """

  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Summary

  @kept_traces 500

  # `controls` keeps every configured/started/stopped entry, `traces` the newest
  # trace and dropped entries; both newest first.
  defstruct controls: [], traces: [], summary: %Summary{}

  @type t :: %__MODULE__{controls: [Entry.t()], traces: [Entry.t()], summary: Summary.t()}

  @doc "Numbers `entries` from `seq` and keeps them. Returns the numbered entries."
  @spec append(t(), [Entry.unnumbered()], non_neg_integer()) :: {[Entry.t()], t()}
  def append(%__MODULE__{} = log, entries, seq) do
    entries = Enum.with_index(entries, &Map.put(&1, :seq, seq + &2))
    {traces, controls} = Enum.split_with(entries, &(&1.kind in [:trace, :dropped]))

    # Dropped entries come with every shed batch, so they are capped with the traces.
    kept = Enum.take(Enum.reverse(traces) ++ log.traces, @kept_traces)

    {entries,
     %{
       log
       | controls: Enum.reverse(controls) ++ log.controls,
         traces: kept,
         summary: Summary.add(log.summary, traces)
     }}
  end

  @doc "The `Voyager.Services.Tracer.entries/2` page of the kept entries, where `next_seq` is the session's."
  @spec page(t(), non_neg_integer(), keyword()) :: %{
          entries: [Entry.t()],
          truncated?: boolean()
        }
  def page(%__MODULE__{} = log, next_seq, opts) do
    since = Keyword.get(opts, :since, 0)
    before = min(Keyword.get(opts, :before, next_seq), next_seq)
    order = opts[:order]
    limit = opts[:limit]

    page =
      (log.controls ++ log.traces)
      |> Enum.filter(&(&1.seq >= since and &1.seq < before))
      |> Enum.sort_by(& &1.seq, order)
      |> Enum.take(limit)

    covered = covered_range(page, since, before, order, length(page) == limit)

    # Seqs have no gaps, so a seq in the covered range without an entry was evicted.
    %{entries: page, truncated?: length(page) < Range.size(covered)}
  end

  # A full page covers the range up to its last entry; a short one the whole range.
  defp covered_range(page, since, _before, :asc, true), do: since..List.last(page).seq//1
  defp covered_range(page, _since, before, :desc, true), do: List.last(page).seq..(before - 1)//1
  defp covered_range(_page, since, before, _order, false), do: since..(before - 1)//1
end
