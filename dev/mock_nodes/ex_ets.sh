#!/usr/bin/env bash
set -euo pipefail

iex --name ex_ets@127.0.0.1 --cookie demo "$(dirname "$0")/ets_demo_node.exs"
