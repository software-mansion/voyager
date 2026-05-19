defmodule Voyager.NodeInfo.Memory do
  @moduledoc """
  Memory usage breakdown for a BEAM node.

  Passive module: builds its struct from a pre-fetched `:erlang.memory/0`
  map via `build/1`. All values are bytes. The `:other` field is the
  memory not attributable to any of the named buckets.

  Process used is part of the process allocated.
  Atom allocated is part of the atom used.
  """

  alias __MODULE__

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          processes_allocated: non_neg_integer(),
          processes_used: non_neg_integer(),
          atom_allocated: non_neg_integer(),
          atom_used: non_neg_integer(),
          binary: non_neg_integer(),
          code: non_neg_integer(),
          ets: non_neg_integer(),
          other: non_neg_integer()
        }

  defstruct [
    :total,
    :processes_allocated,
    :processes_used,
    :atom_allocated,
    :atom_used,
    :binary,
    :code,
    :ets,
    :other
  ]

  @spec build(map()) :: t()
  def build(memory) do
    total = Map.fetch!(memory, :total)

    process_allocated = Map.fetch!(memory, :processes)
    process_used = Map.fetch!(memory, :processes_used)

    atom_allocated = Map.fetch!(memory, :atom)
    atom_used = Map.fetch!(memory, :atom_used)

    binary = Map.fetch!(memory, :binary)
    code = Map.fetch!(memory, :code)
    ets = Map.fetch!(memory, :ets)

    %Memory{
      total: total,
      processes_allocated: process_allocated,
      processes_used: process_used,
      atom_allocated: atom_allocated,
      atom_used: atom_used,
      binary: binary,
      code: code,
      ets: ets,
      other: max(total - (process_allocated + atom_allocated + binary + code + ets), 0)
    }
  end
end
