defmodule Voyager.Language.Gleam do
  @behaviour Voyager.Language

  alias Voyager.Language
  alias Voyager.RPC.ERPC

  @impl Voyager.Language
  def detect?(apps) do
    Enum.any?(apps, fn {name, _desc, _vsn} -> name == :gleam_stdlib end)
  end

  @impl Voyager.Language
  def name, do: "Gleam"

  @impl Voyager.Language
  def info(node) do
    %{
      stdlib_version: Language.app_vsn(node, :gleam_stdlib),
      gleam_modules: gleam_modules(node)
    }
  end

  defp gleam_modules(node) do
    case ERPC.call(node, :code, :all_loaded, [], 5_000) do
      {:ok, modules} ->
        modules
        |> Enum.map(fn {mod, _file} -> Atom.to_string(mod) end)
        |> Enum.filter(&String.contains?(&1, "@"))

      {:error, _} ->
        []
    end
  end
end
