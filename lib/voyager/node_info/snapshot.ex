defmodule Voyager.NodeInfo.Snapshot do
  @moduledoc """
  A single point-in-time snapshot of node introspection data.

  Built by `Voyager.NodeInfo.fetch/2` from the per-concern sub-fetchers.
  """

  alias Voyager.NodeInfo.{Limits, Memory, Runtime, System}

  @type t :: %__MODULE__{
          node: node(),
          collected_at: DateTime.t(),
          system: System.t(),
          memory: Memory.t(),
          runtime: Runtime.t(),
          limits: Limits.t(),
          voyager_version: String.t()
        }

  defstruct [
    :node,
    :collected_at,
    :system,
    :memory,
    :runtime,
    :limits,
    :voyager_version
  ]
end
