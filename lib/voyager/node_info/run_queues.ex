defmodule Voyager.NodeInfo.RunQueues do
  @moduledoc """
  Run queue depths for a BEAM node.
  """

  @statistics_keys [
    :total_run_queue_lengths_all,
    :total_run_queue_lengths
  ]

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          cpu: non_neg_integer(),
          io: non_neg_integer()
        }

  defstruct [:total, :cpu, :io]

  @spec statistics_keys() :: [atom()]
  def statistics_keys, do: @statistics_keys

  @spec build(map()) :: t()
  def build(stat) do
    total = Map.fetch!(stat, :total_run_queue_lengths_all)
    cpu = Map.fetch!(stat, :total_run_queue_lengths)

    %__MODULE__{total: total, cpu: cpu, io: max(total - cpu, 0)}
  end
end
