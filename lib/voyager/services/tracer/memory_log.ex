defmodule Voyager.Services.Tracer.MemoryLog do
  @moduledoc false

  alias Voyager.Services.Tracer

  @kept_traces 500

  # `controls` keeps every configured/started/stopped entry, `traces` the newest
  # trace and dropped entries; both newest first.
  defstruct controls: [], traces: []

  @type t :: %__MODULE__{controls: [Tracer.entry()], traces: [Tracer.entry()]}

  @doc "Numbers `entries` from `seq` and keeps them. Returns the numbered entries."
  @spec append(t(), [map()], non_neg_integer()) :: {[Tracer.entry()], t()}
  def append(%__MODULE__{} = log, entries, seq) do
    entries = Enum.with_index(entries, &Map.put(&1, :seq, seq + &2))

    {traces, controls} =
      Enum.split_with(entries, &(&1.kind in [:trace, :dropped]))

    # Dropped entries come with every shed batch, so they are capped with the traces.
    kept = Enum.take(Enum.reverse(traces) ++ log.traces, @kept_traces)

    {entries, %{log | controls: Enum.reverse(controls) ++ log.controls, traces: kept}}
  end

  @doc "The `Voyager.Services.Tracer.entries/2` page of the kept entries, where `next_seq` is the session's."
  @spec page(t(), non_neg_integer(), keyword()) :: %{
          entries: [Tracer.entry()],
          truncated?: boolean()
        }
  def page(%__MODULE__{} = log, next_seq, opts) do
    since = Keyword.get(opts, :since, 0)
    before = min(Keyword.get(opts, :before, next_seq), next_seq)
    order = opts[:order]

    page =
      (log.controls ++ log.traces)
      |> Enum.filter(&(&1.seq >= since and &1.seq < before))
      |> Enum.sort_by(& &1.seq, order)
      |> Enum.take(opts[:limit])

    # Seqs have no gaps, so a seq in the covered range without an entry was evicted.
    # A full page covers the range up to its last entry; a short one the whole range.
    covered =
      case {order, length(page) == opts[:limit]} do
        {:asc, true} -> since..List.last(page).seq//1
        {:desc, true} -> List.last(page).seq..(before - 1)//1
        _short -> since..(before - 1)//1
      end

    %{entries: page, truncated?: length(page) < Range.size(covered)}
  end
end
