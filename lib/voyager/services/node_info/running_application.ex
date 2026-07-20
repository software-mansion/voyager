defmodule Voyager.Services.NodeInfo.RunningApplication do
  @moduledoc """
  A running OTP application on a node, as reported by
  `:application.which_applications/0`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          version: String.t()
        }

  @derive JSON.Encoder
  defstruct [:name, :description, :version]

  @spec build([{atom(), charlist(), charlist()}]) :: [t()]
  def build(which_applications) do
    which_applications
    |> Enum.map(fn {name, description, version} ->
      %__MODULE__{name: name, description: to_string(description), version: to_string(version)}
    end)
    |> Enum.sort_by(& &1.name)
  end
end
