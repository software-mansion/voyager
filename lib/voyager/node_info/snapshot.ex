defmodule Voyager.NodeInfo.Snapshot do
  @moduledoc """
  A single point-in-time snapshot of node introspection data.

  Built by `Voyager.NodeInfo.fetch/2` from the per-concern sub-fetchers.
  """

  alias Voyager.NodeInfo.Language
  alias Voyager.NodeInfo.Limits
  alias Voyager.NodeInfo.Memory
  alias Voyager.NodeInfo.Processors
  alias Voyager.NodeInfo.RunQueues
  alias Voyager.NodeInfo.Schedulers
  alias Voyager.NodeInfo.Statistics
  alias Voyager.NodeInfo.SystemInfo

  @type t :: %__MODULE__{
          node: node(),
          collected_at: DateTime.t(),
          system: SystemInfo.t(),
          languages: [Language.t()],
          memory: Memory.t(),
          runtime: Statistics.t(),
          limits: Limits.t(),
          processors: Processors.t(),
          schedulers: Schedulers.t(),
          run_queues: RunQueues.t()
        }

  defstruct [
    :node,
    :collected_at,
    :system,
    :languages,
    :memory,
    :runtime,
    :limits,
    :processors,
    :schedulers,
    :run_queues
  ]
end
