#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.node.pid"
PID_FILE_V6="$SCRIPT_DIR/.node6.pid"
MOCK_APP_DIR="$SCRIPT_DIR/mock_app"

start() {
  pkill -f "erl.*test@127.0.0.1" 2>/dev/null || true
  pkill -f "erl.*test6@::1" 2>/dev/null || true
  rm -f "$PID_FILE" "$PID_FILE_V6"

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

  erl -name test6@::1 \
      -proto_dist inet6_tcp \
      -setcookie e2e_cookie \
      -noshell \
      -noinput \
      -kernel inet_dist_listen_min 9002 inet_dist_listen_max 9002 > /dev/null 2>&1 &

  echo $! > "$PID_FILE_V6"
  echo "IPv6 test node started (PID $(cat "$PID_FILE_V6"))"
}

stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  else
    pkill -f "erl.*test@127.0.0.1" 2>/dev/null || true
  fi

  if [ -f "$PID_FILE_V6" ]; then
    kill "$(cat "$PID_FILE_V6")" 2>/dev/null || true
    rm -f "$PID_FILE_V6"
  else
    pkill -f "erl.*test6@::1" 2>/dev/null || true
  fi

  echo "Test nodes stopped"
}

case "${1:-}" in
  start) start ;;
  stop)  stop  ;;
  *) echo "Usage: $0 start|stop" >&2; exit 1 ;;
esac
