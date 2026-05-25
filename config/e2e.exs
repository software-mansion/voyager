import Config

config :voyager, Voyager.Repo,
  database: Path.expand("../priv/db/voyager_e2e.db", __DIR__),
  pool_size: 5

config :voyager, VoyagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  secret_key_base: "e2e00000000000000000000000000000000000000000000000000000000000000000",
  server: true

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
