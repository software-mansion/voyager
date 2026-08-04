#!/usr/bin/env bash
#
# Benchmark e2e test flakiness.
#
# Runs the full Playwright suite N times, each time with --retries so Playwright
# classifies tests that fail-then-pass as "flaky". One JSON report is written per
# run, then aggregate-flakiness.mjs turns the whole batch into a per-test report.
#
# The suite cannot be parallelized (project dependency chain + shared node state),
# so runs are strictly sequential. A fresh mock node is started per run for
# isolated, comparable state. A failing suite never aborts the batch.
#
# Usage:
#   ./bench-flakiness.sh [RUNS] [RETRIES]
#
#   RUNS     how many times to run the full suite   (default 20)
#   RETRIES  Playwright --retries per run            (default 2)
#
# Example:
#   ./bench-flakiness.sh 30 2
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RUNS="${1:-20}"
RETRIES="${2:-2}"
RESULTS_DIR="$SCRIPT_DIR/flakiness-results"

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# Always leave the machine clean, even on Ctrl-C.
trap 'bash "$SCRIPT_DIR/node.sh" stop >/dev/null 2>&1 || true' EXIT

echo "Benchmarking e2e flakiness: $RUNS run(s) x (1 attempt + $RETRIES retries)"
echo "Results -> $RESULTS_DIR"

for i in $(seq 1 "$RUNS"); do
  printf '\n=== Run %d/%d ===\n' "$i" "$RUNS"
  idx="$(printf '%03d' "$i")"
  run_json="$RESULTS_DIR/run-$idx.json"
  run_log="$RESULTS_DIR/run-$idx.log"

  # Fresh target node each run so state mutations don't leak between runs.
  bash "$SCRIPT_DIR/node.sh" start >/dev/null 2>&1

  # Phoenix is started/reused by Playwright's webServer config.
  # `|| true` keeps a failing suite from killing the batch — a fail is data.
  PLAYWRIGHT_JSON_OUTPUT_NAME="$run_json" \
    npx playwright test --retries="$RETRIES" --reporter=json \
    >"$run_log" 2>&1 || true

  bash "$SCRIPT_DIR/node.sh" stop >/dev/null 2>&1

  if [ -f "$run_json" ]; then
    echo "  report: $run_json"
  else
    echo "  WARNING: no JSON report produced (see $run_log)"
  fi
done

echo
echo "==================================================================="
node "$SCRIPT_DIR/aggregate-flakiness.mjs" "$RESULTS_DIR"
