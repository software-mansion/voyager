import Config

if System.get_env("PHX_SERVER") do
  config :voyager, VoyagerWeb.Endpoint, server: true
end

if config_env() != :e2e do
  config :voyager, VoyagerWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() not in [:test, :e2e] do
  config :voyager, Voyager.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Voyager.VaultKey.resolve!()}
    ]
end

if url = System.get_env("TELEMETRY_PUSH_URL") do
  config :voyager, telemetry_push_url: url
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

  host = System.get_env("PHX_HOST") || "example.com"

  # Behind TLS in production use PHX_URL_SCHEME=https and PHX_URL_PORT=443 (defaults).
  # For local prod (PHX_HOST=localhost), default to the HTTP port you actually serve on.
  scheme =
    System.get_env("PHX_URL_SCHEME") ||
      if(host in ["localhost", "127.0.0.1"], do: "http", else: "https")

  port =
    (System.get_env("PHX_URL_PORT") ||
       if(host in ["localhost", "127.0.0.1"], do: System.get_env("PORT") || "4000", else: "443"))
    |> String.to_integer()

  config :voyager, VoyagerWeb.Endpoint,
    url: [host: host, port: port, scheme: scheme],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    check_origin: [
      "//#{host}",
      "//127.0.0.1"
    ]
end
