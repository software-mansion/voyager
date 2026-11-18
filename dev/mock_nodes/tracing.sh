#!/usr/bin/env bash
set -euo pipefail

iex --name tracing@127.0.0.1 --cookie demo "$(dirname "$0")/tracing_demo_node.exs"
