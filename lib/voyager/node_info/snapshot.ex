defmodule Voyager.NodeInfo.Snapshot do
  @moduledoc """
  A single point-in-time snapshot of node introspection data.

  Built by `Voyager.NodeInfo.fetch/2` from the per-concern sub-fetchers.
  """

  alias Voyager.NodeInfo.{Limits, Memory, Processors, Schedulers, Statistics, System}

  @type t :: %__MODULE__{
          node: node(),
          collected_at: DateTime.t(),
          system: System.t(),
          memory: Memory.t(),
          runtime: Statistics.t(),
          limits: Limits.t(),
          processors: Processors.t(),
          schedulers: Schedulers.t()
        }

  defstruct [
    :node,
    :collected_at,
    :system,
    :memory,
    :runtime,
    :limits,
    :processors,
    :schedulers
  ]
end
