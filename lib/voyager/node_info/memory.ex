defmodule Voyager.NodeInfo.Memory do
  @moduledoc """
  Memory usage breakdown for a BEAM node.

  Passive module: builds its struct from a pre-fetched `:erlang.memory/0`
  map via `build/1`. All values are bytes. The `:other` field is the
  memory not attributable to any of the named buckets.
  """

  alias __MODULE__

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          processes: non_neg_integer(),
          atom: non_neg_integer(),
          binary: non_neg_integer(),
          code: non_neg_integer(),
          ets: non_neg_integer(),
          other: non_neg_integer()
        }

  defstruct [
    :total,
    :processes,
    :atom,
    :binary,
    :code,
    :ets,
    :other
  ]

  @spec build(map()) :: t()
  def build(memory) do
    total = Map.fetch!(memory, :total)
    processes = Map.fetch!(memory, :processes)
    atom = Map.fetch!(memory, :atom)
    binary = Map.fetch!(memory, :binary)
    code = Map.fetch!(memory, :code)
    ets = Map.fetch!(memory, :ets)

    %Memory{
      total: total,
      processes: processes,
      atom: atom,
      binary: binary,
      code: code,
      ets: ets,
      other: max(total - (processes + atom + binary + code + ets), 0)
    }
  end
end
