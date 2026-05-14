import Config

config :voyager, Voyager.Repo,
  database: Path.expand("../voyager_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :voyager, VoyagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "4hq+f3KGSasv5x87v5n5FXZ9brshu4AwYTLlNm42GwSJtlY6S5z6cLQ3lH5dJlZ7",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:voyager, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:voyager, ~w(--watch)]}
  ]

config :voyager, VoyagerWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
~r"lib/voyager_web/router\.ex$"E,
      ~r"lib/voyager_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :voyager, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
