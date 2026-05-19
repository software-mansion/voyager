defmodule Voyager.NodeInfo.Schedulers do
  @moduledoc """
  Scheduler counts for the BEAM node.
  """

  @system_info_keys [
    :schedulers,
    :schedulers_online,
    :multi_scheduling
  ]

  @type t :: %__MODULE__{
          total: pos_integer(),
          online: pos_integer(),
          available: pos_integer()
        }

  defstruct [:total, :online, :available]

  @spec system_info_keys() :: [atom()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(system_info) do
    online = Map.fetch!(system_info, :schedulers_online)

    %__MODULE__{
      total: Map.fetch!(system_info, :schedulers),
      online: online,
      available: available(system_info)
    }
  end

  defp available(system_info) do
    case Map.fetch!(system_info, :multi_scheduling) do
      :enabled -> Map.fetch!(system_info, :schedulers_online)
      _ -> 1
    end
  end
end
