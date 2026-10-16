#!/usr/bin/env bash
set -euo pipefail

dev="$(cd "$(dirname "$0")/.." && pwd)"
ebin="$(mktemp -d)"
erlc -o "$ebin" "$dev/ets_demo_node.erl"

exec erl -name ets_erl@127.0.0.1 -setcookie demo -pa "$ebin" -eval 'ets_demo_node:start()'
