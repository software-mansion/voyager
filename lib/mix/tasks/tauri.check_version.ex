defmodule Mix.Tasks.Tauri.CheckVersion do
  @shortdoc "Verifies mix.exs, tauri.conf.json, and Cargo.toml versions all match"
  @moduledoc """
  Checks that the application version in `mix.exs` is in sync with the Tauri
  configuration files. Exits with a non-zero status if any version diverges.

      $ mix tauri.check_version

  To fix a mismatch, run:

      $ mix tauri.sync_version

  This task is included in the `precommit` alias so version drift is caught
  before code is committed.
  """

  use Mix.Task

  @tauri_conf "rel/app/src-tauri/tauri.conf.json"
  @cargo_toml "rel/app/src-tauri/Cargo.toml"

  @impl Mix.Task
  def run(_args) do
    mix_version = Mix.Project.config()[:version]

    checks = [
      {@tauri_conf, tauri_conf_version()},
      {@cargo_toml, cargo_toml_version()}
    ]

    mismatches =
      Enum.filter(checks, fn {_file, version} -> version != mix_version end)

    if mismatches == [] do
      Mix.shell().info("Version check passed — all files are at #{mix_version}")
    else
      Enum.each(mismatches, fn {file, version} ->
        Mix.shell().error(
          "#{file}: found #{inspect(version)}, expected #{inspect(mix_version)} (from mix.exs)"
        )
      end)

      Mix.raise("Version mismatch detected")
    end
  end

  defp tauri_conf_version do
    @tauri_conf |> File.read!() |> Jason.decode!() |> Map.get("version")
  end

  defp cargo_toml_version do
    @cargo_toml |> File.read!() |> TomlElixir.decode!() |> get_in(["package", "version"])
  end
end
