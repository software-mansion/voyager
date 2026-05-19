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
  def build(si) do
    online = Map.fetch!(si, :schedulers_online)

    %__MODULE__{
      total: Map.fetch!(si, :schedulers),
      online: online,
      available: available(si)
    }
  end

  defp available(si) do
    case Map.fetch!(si, :multi_scheduling) do
      :enabled -> Map.fetch!(si, :schedulers_online)
      _ -> 1
    end
  end
end
