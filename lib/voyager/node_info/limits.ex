defmodule Voyager.NodeInfo.Limits do
  @moduledoc """
  Used-vs-limit counters for capped node-wide resources: atoms,
  processes, ports, and ETS tables. Each entry includes a pre-computed
  `:used_pct` (a float in 0.0..1.0).

  Passive module: declares the `:erlang.system_info/1` keys it needs via
  `system_info_keys/0` and builds its struct from pre-fetched data via
  `build/1`.
  """

  alias __MODULE__

  @resources [
    {:atoms, :atom_count, :atom_limit},
    {:processes, :process_count, :process_limit},
    {:ports, :port_count, :port_limit},
    {:ets, :ets_count, :ets_limit}
  ]

  @system_info_keys Enum.flat_map(@resources, fn {_key, count, limit} -> [count, limit] end)

  @type usage :: %{
          used: non_neg_integer(),
          limit: pos_integer()
        }

  @type t :: %__MODULE__{
          atoms: usage(),
          processes: usage(),
          ports: usage(),
          ets: usage()
        }

  defstruct [:atoms, :processes, :ports, :ets]

  @spec system_info_keys() :: [atom()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(si) do
    Enum.reduce(@resources, %Limits{}, fn {key, count_key, limit_key}, acc ->
      Map.put(acc, key, %{used: Map.fetch!(si, count_key), limit: Map.fetch!(si, limit_key)})
    end)
  end
end
