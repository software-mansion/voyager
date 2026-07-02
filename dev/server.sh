#!/usr/bin/env bash
set -euo pipefail

# Boots the Phoenix server with Voyager.ProxyEpmd as the distribution epmd
# module so remote nodes resolve through SSH tunnels. Distribution is started
# and the remote cookie is set at connect time, so no --name/--cookie is needed.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mix compile

env="${MIX_ENV:-dev}"
ebin="$PWD/_build/$env/lib/voyager/ebin"

exec iex --erl "-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" -S mix phx.server
