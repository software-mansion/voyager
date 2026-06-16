# powershell -ExecutionPolicy Bypass -File dev\prod_with_secrets.ps1
# Or once: Set-ExecutionPolicy -Scope CurrentUser Bypass

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$env:MIX_ENV = "prod"
$env:DATABASE_PATH = "priv/db/voyager_prod.db"
$env:TELEMETRY_PUSH_URL = "http://127.0.0.1:4310/telemetry"
$env:SECRET_KEY_BASE = "EoaZBjLjm/W+OmiaGW7kY6MP204JuaVG5Yl7G1Q98AZdgno+4XM36EnW3rpI8o3u"
$env:PHX_HOST = "localhost"
$env:PORT = "4000"
$env:POOL_SIZE = "5"

mix setup
mix assets.deploy
mix compile
iex.bat -S mix phx.server
