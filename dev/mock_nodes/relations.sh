#!/usr/bin/env bash
set -euo pipefail
 
iex --name relations@127.0.0.1 --cookie demo "$(dirname "$0")/relations_demo_node.exs"