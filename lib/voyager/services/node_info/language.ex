defmodule Voyager.Services.NodeInfo.Language do
  @moduledoc """
  A BEAM language detected on a node, with its version.

  Each supported language ships as an OTP application:
    * Elixir → `:elixir`
    * Gleam → `:gleam_stdlib` (Gleam itself is a compile-to-BEAM
      language with no runtime application of its own — the closest
      proxy available on the node is the stdlib package)
  """

  @applications [
    {:elixir, "Elixir"},
    {:gleam_stdlib, "Gleam (stdlib)"}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t()
        }

  defstruct [:name, :version]

  @spec candidate_apps() :: [atom()]
  @candidate_apps Enum.map(@applications, fn {app, _name} -> app end)

  @spec candidate_apps() :: [atom()]
  def candidate_apps, do: @candidate_apps

  @spec build([{atom(), :undefined | {:ok, charlist()}}]) :: [t()]
  def build(app_versions) do
    versions = for {app, {:ok, vsn}} <- app_versions, into: %{}, do: {app, vsn}

    for {app, name} <- @applications, is_map_key(versions, app) do
      %__MODULE__{name: name, version: to_string(Map.fetch!(versions, app))}
    end
  end
end
