#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix compile

env="${MIX_ENV:-dev}"
ebin="$PWD/_build/$env/lib/voyager/ebin"

exec iex \
  --name voyager_test@127.0.0.1 --cookie test \
  --erl "-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" \
  -S mix phx.server
