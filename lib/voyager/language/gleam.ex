defmodule Voyager.Language.Gleam do
  @moduledoc false

  @behaviour Voyager.Language

  alias Voyager.Language

  @impl Voyager.Language
  def detect?(apps) do
    Enum.any?(apps, fn {name, _desc, _vsn} -> name == :gleam_stdlib end)
  end

  @impl Voyager.Language
  def name, do: "Gleam"

  @impl Voyager.Language
  def info(node) do
    %{stdlib_version: Language.app_vsn(node, :gleam_stdlib)}
  end
end
