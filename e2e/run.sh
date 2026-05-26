#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/node.sh" start
trap "bash '$SCRIPT_DIR/node.sh' stop" EXIT

cd "$SCRIPT_DIR"
./node_modules/.bin/playwright test "$@"
