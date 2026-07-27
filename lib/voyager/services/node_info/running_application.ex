defmodule Voyager.Services.NodeInfo.RunningApplication do
  @moduledoc """
  A running OTP application on a node, as reported by
  `:application.which_applications/0`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          version: String.t(),
          has_supervision_tree: boolean()
        }

  @derive JSON.Encoder
  defstruct [:name, :description, :version, :has_supervision_tree]

  @spec build([{atom(), charlist(), charlist()}], [pid() | :undefined]) :: [t()]
  def build(which_applications, application_masters) do
    which_applications
    |> Enum.zip(application_masters)
    |> Enum.map(fn {{name, description, version}, master} ->
      %__MODULE__{
        name: name,
        description: to_string(description),
        version: to_string(version),
        has_supervision_tree: master != :undefined
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
