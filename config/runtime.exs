import Config

telemetry_push_url = System.get_env("TELEMETRY_PUSH_URL")
config :voyager, telemetry_push_url: telemetry_push_url
config :voyager, :env, config_env()

if config_env() == :dev do
  config :voyager, :telemetry, if(telemetry_push_url in [nil, ""], do: :logger, else: :export)
end

if System.get_env("PHX_SERVER") do
  config :voyager, VoyagerWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

if config_env() != :e2e do
  config :voyager, VoyagerWeb.Endpoint, http: [port: port]
end

if config_env() not in [:test, :e2e] do
  config :voyager, Voyager.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Voyager.VaultKey.resolve!()}
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/voyager/voyager.db
      """

  config :voyager, Voyager.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "localhost")

  config :voyager, VoyagerWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
