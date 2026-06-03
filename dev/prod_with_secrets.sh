#!/usr/bin/env bash
# Simple script to run the server in production mode. `.env` leaked to test sandbox.

env=prod
database_path=priv/db/voyager_prod.db
telemetry_push_url=http://127.0.0.1:4310/telemetry
secret_key_base=EoaZBjLjm/W+OmiaGW7kY6MP204JuaVG5Yl7G1Q98AZdgno+4XM36EnW3rpI8o3u
phx_host=localhost
port=4000
pool_size=5

env \
  MIX_ENV="$env" \
  PHX_HOST="$phx_host" \
  PORT="$port" \
  SECRET_KEY_BASE="$secret_key_base" \
  DATABASE_PATH="$database_path" \
  POOL_SIZE="$pool_size" \
  TELEMETRY_PUSH_URL="$telemetry_push_url" \
  bash -c '
    mix setup
    mix assets.deploy
    mix compile
    iex -S mix phx.server
  '
