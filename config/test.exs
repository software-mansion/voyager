import Config

# Disable node info auto-refresh in tests so LiveViews don't schedule timers.
config :voyager, :node_info_refresh_interval_ms, nil

# Tests drive refreshes back to back; rate limiting is exercised explicitly in
# details_panel_test.exs.
config :voyager, :process_info_min_refresh_ms, 0

config :voyager, Voyager.Vault,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: <<0::256>>}
  ]

config :voyager, Voyager.Repo,
  database: Path.expand("../priv/db/voyager_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :voyager, Voyager.MCP, enabled: false

config :voyager, VoyagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xadc/ex/aZLzBKM3evVVaZqtQyL16e/3cb8k81ThIB0OcCuTx0wQifiVdQFuGk6E",
  server: false

config :voyager, :telemetry_handler, :noop

# Skip the first-launch onboarding modal so unrelated LiveView tests are not blocked.
config :voyager, :terms_accepted, true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix, sort_verified_routes_query_params: true
