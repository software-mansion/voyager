#!/usr/bin/env bash
set -euo pipefail

ebin="$(mktemp -d)"
erlc -o "$ebin" "$(cd "$(dirname "$0")" && pwd)/ets_demo_node.erl"

exec erl -name erl_ets@127.0.0.1 -setcookie demo -pa "$ebin" -eval 'ets_demo_node:start()'
