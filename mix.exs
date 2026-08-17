defmodule Voyager.MixProject do
  use Mix.Project

  def project do
    [
      app: :voyager,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def application do
    [
      mod: {Voyager.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, e2e: :e2e, "e2e.setup": :e2e]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:anubis_mcp, "~> 2.0"},
      {:bandit, "~> 1.12"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:elixirkit, github: "livebook-dev/elixirkit"},
      {:jason, "~> 1.2"},
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.9.0"},
      {:phoenix_live_view, "~> 1.2.8"},
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:live_debugger, "~> 1.0", only: [:dev]},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:tailwind_formatter, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      format: ["format", "cmd npm --prefix assets run format"],
      "e2e.format": ["cmd npm --prefix e2e run format"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "e2e.setup": [
        "cmd --cd e2e npm ci",
        "cmd --cd e2e npx playwright install --with-deps"
      ],
      "tauri.dev": ["cmd bash ./rel/app/tauri.sh dev"],
      "tauri.app": ["cmd bash ./rel/app/tauri.sh app"],
      "tauri.build": ["cmd bash ./rel/app/tauri.sh build"],
      "tauri.test": ["cmd --cd rel/app/src-tauri cargo test"],
      "tauri.format": ["cmd --cd rel/app/src-tauri cargo fmt"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd npm install --prefix assets"
      ],
      "assets.build": [
        "phx.digest.clean --all",
        "cmd npm --prefix assets run format",
        copy_font_assets_cmd(),
        "compile",
        "tailwind voyager --minify",
        "esbuild voyager --minify"
      ],
      "assets.deploy": [
        "assets.build",
        "phx.digest"
      ],
      e2e: [
        "ecto.reset",
        "cmd bash e2e/run.sh"
      ],
      precommit: [
        tauri_check_version_cmd(),
        elixirkit_check_rev_cmd(),
        "deps.unlock --unused",
        "compile --warnings-as-errors",
        "format",
        "credo --strict",
        "e2e.format",
        "tauri.format",
        "test",
        "tauri.test"
      ]
    ]
  end

  defp releases do
    [
      voyager: [
        rel_templates_path: "rel/app",
        steps: [:assemble, &ElixirKit.Release.codesign/1],
        entitlements: "#{__DIR__}/rel/app/src-tauri/App.entitlements"
      ]
    ]
  end

  defp copy_font_assets_cmd do
    script =
      "cp -f -- assets/node_modules/@fontsource-variable/dm-sans/files/dm-sans-latin-wght-normal.woff2 priv/static/fonts/ &&
      cp -f -- assets/vendor/fonts/jetbrains-mono-latin-wght-normal.woff2 priv/static/fonts/"

    "cmd sh -c '#{script}'"
  end

  defp tauri_check_version_cmd, do: "cmd dev/tauri_check_version.sh"

  defp elixirkit_check_rev_cmd, do: "cmd dev/elixirkit_check_rev.sh"
end
