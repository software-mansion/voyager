defmodule Voyager.Services.NodeInfo.Snapshot do
  @moduledoc """
  A single point-in-time snapshot of node introspection data.

  Built by `Voyager.Services.NodeInfo.fetch/2` from the per-concern sub-fetchers.
  """

  alias Voyager.Services.NodeInfo.Language
  alias Voyager.Services.NodeInfo.Limits
  alias Voyager.Services.NodeInfo.Memory
  alias Voyager.Services.NodeInfo.RunQueues
  alias Voyager.Services.NodeInfo.Schedulers
  alias Voyager.Services.NodeInfo.Statistics
  alias Voyager.Services.NodeInfo.SystemInfo

  @type t :: %__MODULE__{
          node: node(),
          collected_at: DateTime.t(),
          system: SystemInfo.t(),
          languages: [Language.t()],
          memory: Memory.t(),
          runtime: Statistics.t(),
          limits: Limits.t(),
          schedulers: Schedulers.t(),
          run_queues: RunQueues.t()
        }

  @derive JSON.Encoder
  defstruct [
    :node,
    :collected_at,
    :system,
    :languages,
    :memory,
    :runtime,
    :limits,
    :schedulers,
    :run_queues
  ]
end
