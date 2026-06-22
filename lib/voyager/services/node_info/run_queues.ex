defmodule Voyager.Services.NodeInfo.RunQueues do
  @moduledoc """
  Run queue depths for a BEAM node.

  The BEAM has three classes of scheduler run queues:

    * normal schedulers — run regular Erlang processes
    * dirty CPU schedulers — run CPU-bound dirty NIFs
    * dirty IO schedulers — run IO-bound dirty NIFs

  Fields:

    * `:total` — sum of all run queue lengths across normal, dirty CPU,
      and dirty IO schedulers (`:total_run_queue_lengths_all`).
    * `:normal_and_dirty_cpu` — sum of run queue lengths across normal
      and dirty CPU schedulers (`:total_run_queue_lengths`). Does **not**
      include dirty IO.
    * `:dirty_io` — derived as `total - normal_and_dirty_cpu`; the run
      queue length across dirty IO schedulers only.
  """

  @statistics_keys [
    :total_run_queue_lengths_all,
    :total_run_queue_lengths
  ]

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          normal_and_dirty_cpu: non_neg_integer(),
          dirty_io: non_neg_integer()
        }

  @derive JSON.Encoder
  defstruct [:total, :normal_and_dirty_cpu, :dirty_io]

  @spec statistics_keys() :: [atom()]
  def statistics_keys, do: @statistics_keys

  @spec build(map()) :: t()
  def build(stat) do
    total = Map.fetch!(stat, :total_run_queue_lengths_all)
    normal_and_dirty_cpu = Map.fetch!(stat, :total_run_queue_lengths)

    %__MODULE__{
      total: total,
      normal_and_dirty_cpu: normal_and_dirty_cpu,
      dirty_io: max(total - normal_and_dirty_cpu, 0)
    }
  end
end
