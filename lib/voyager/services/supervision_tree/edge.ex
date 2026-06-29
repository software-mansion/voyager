defmodule Voyager.Services.SupervisionTree.Edge do
  @moduledoc """
  A relationship edge between two nodes in the supervision tree.

  ## Edge keys:

    * `"rel:<kind>:<source>-><target>"`.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :source, :target, :kind]
  defstruct [:id, :source, :target, :kind]

  @type t :: %__MODULE__{
          id: String.t(),
          source: pid() | port() | reference(),
          target: pid() | port() | reference(),
          kind: :link | :monitor | :monitored_by
        }
end
