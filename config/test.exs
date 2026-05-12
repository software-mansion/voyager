import Config

config :voyager, Voyager.Repo,
  database: Path.expand("../voyager_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :voyager, VoyagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xadc/ex/aZLzBKM3evVVaZqtQyL16e/3cb8k81ThIB0OcCuTx0wQifiVdQFuGk6E",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix, sort_verified_routes_query_params: true
