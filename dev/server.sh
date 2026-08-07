#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mix compile

env="${MIX_ENV:-dev}"
ebin="$PWD/_build/$env/lib/voyager/ebin"

exec iex --erl "-proto_dist inet6_tcp -epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" -S mix phx.server
