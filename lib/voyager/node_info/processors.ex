defmodule Voyager.NodeInfo.Processors do
  @moduledoc """
  Logical processor counts reported by the BEAM.
  """

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
  def build(system_info) do
    %__MODULE__{
      total: Map.fetch!(system_info, :logical_processors),
      online: Map.fetch!(system_info, :logical_processors_online),
      available: Map.fetch!(system_info, :logical_processors_available)
    }
  end
end
