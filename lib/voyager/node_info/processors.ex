defmodule Voyager.NodeInfo.Processors do
  @moduledoc """
  Logical processor counts reported by the BEAM: total detected, online,
  and available to the scheduler.

  Passive module: declares the `:erlang.system_info/1` keys it needs via
  `system_info_keys/0` and builds its struct from pre-fetched data via
  `build/1`.
  """

  alias __MODULE__

  @system_info_keys [
    :logical_processors,
    :logical_processors_online,
    :logical_processors_available
  ]

  @type t :: %__MODULE__{
          total: pos_integer() | :unknown,
          online: pos_integer() | :unknown,
          available: pos_integer() | :unknown
        }

  defstruct [:total, :online, :available]

  @spec system_info_keys() :: [atom()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(si) do
    %Processors{
      total: Map.fetch!(si, :logical_processors),
      online: Map.fetch!(si, :logical_processors_online),
      available: Map.fetch!(si, :logical_processors_available)
    }
  end
end
