defmodule Voyager.Language.Elixir do
  @behaviour Voyager.Language

  alias Voyager.Language
  alias Voyager.RPC.ERPC

  @impl Voyager.Language
  def detect?(apps) do
    Enum.any?(apps, fn {name, _desc, _vsn} -> name == :elixir end)
  end

  @impl Voyager.Language
  def name, do: "Elixir"

  @impl Voyager.Language
  def info(node) do
    %{
      elixir_version: ERPC.fetch(node, System, :version, []),
      mix_version: Language.app_vsn(node, :mix),
      phoenix_version: Language.app_vsn(node, :phoenix),
      ecto_version: Language.app_vsn(node, :ecto)
    }
  end
end
