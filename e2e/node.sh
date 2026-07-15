#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.node.pid"
MOCK_APP_DIR="$SCRIPT_DIR/mock_app"

start() {
  pkill -f "erl.*test@127.0.0.1" 2>/dev/null || true
  rm -f "$PID_FILE"

  erlc -o "$MOCK_APP_DIR/ebin" "$MOCK_APP_DIR/src"/*.erl

  erl -name test@127.0.0.1 \
      -setcookie e2e_cookie \
      -noshell \
      -noinput \
      -pa "$MOCK_APP_DIR/ebin" \
      -eval '{ok, _} = application:ensure_all_started(mock_app)' \
      -kernel inet_dist_listen_min 9001 inet_dist_listen_max 9001 > /dev/null 2>&1 &
      
  echo $! > "$PID_FILE"
  echo "Test node started (PID $(cat "$PID_FILE"))"
}

stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  else
    pkill -f "erl.*test@127.0.0.1" 2>/dev/null || true
  fi
  echo "Test node stopped"
}

case "${1:-}" in
  start) start ;;
  stop)  stop  ;;
  *) echo "Usage: $0 start|stop" >&2; exit 1 ;;
esac
