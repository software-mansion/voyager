defmodule Voyager.Services.NodeInfo.Schedulers do
  @moduledoc """
  Scheduler thread counts for a BEAM node.

  The BEAM runs three classes of scheduler threads:

    * normal schedulers — run regular Erlang processes
    * dirty CPU schedulers — run CPU-bound dirty NIFs
    * dirty IO schedulers — run IO-bound dirty NIFs

  Normal and dirty-CPU schedulers can be taken online/offline at runtime,
  so each exposes a configured total and a currently-online count. Dirty IO
  schedulers are fixed at startup and have no online/offline distinction.

  Fields:

    * `:total` — configured normal schedulers (`:schedulers`)
    * `:online` — currently online normal schedulers (`:schedulers_online`)
    * `:dirty_cpu` — configured dirty CPU schedulers (`:dirty_cpu_schedulers`)
    * `:dirty_cpu_online` — online dirty CPU schedulers (`:dirty_cpu_schedulers_online`)
    * `:dirty_io` — dirty IO schedulers (`:dirty_io_schedulers`)
  """

  @system_info_keys [
    :schedulers,
    :schedulers_online,
    :dirty_cpu_schedulers,
    :dirty_cpu_schedulers_online,
    :dirty_io_schedulers
  ]

  @type t :: %__MODULE__{
          total: pos_integer(),
          online: pos_integer(),
          dirty_cpu: non_neg_integer(),
          dirty_cpu_online: non_neg_integer(),
          dirty_io: non_neg_integer()
        }

  defstruct [
    :total,
    :online,
    :dirty_cpu,
    :dirty_cpu_online,
    :dirty_io
  ]

  @spec system_info_keys() :: [atom()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(system_info) do
    %__MODULE__{
      total: Map.fetch!(system_info, :schedulers),
      online: Map.fetch!(system_info, :schedulers_online),
      dirty_cpu: Map.fetch!(system_info, :dirty_cpu_schedulers),
      dirty_cpu_online: Map.fetch!(system_info, :dirty_cpu_schedulers_online),
      dirty_io: Map.fetch!(system_info, :dirty_io_schedulers)
    }
  end
end
