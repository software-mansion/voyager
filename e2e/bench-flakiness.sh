#!/usr/bin/env bash
#
# Benchmark e2e test flakiness.
#
# Runs the whole suite RUNS times; within a run, failed tests are rerun up to RETRIES times
# (`mix e2e --failed`), so a test that fails and then passes counts as flaky. Voyager.E2E.
# FlakinessFormatter logs every attempt to flakiness-results/run-XXX.jsonl, and
# aggregate_flakiness.exs turns the logs into summary.txt and summary.json (and, in CI, a
# job summary and annotations). If a test's failures over the batch exceed THRESHOLD the
# script exits non-zero, so the CI job fails; otherwise it exits 0.
#
# The suite shares one node and one app, so runs are strictly sequential. A failing run
# never aborts the batch.
#
# Usage: e2e/bench-flakiness.sh [RUNS] [RETRIES] [THRESHOLD]
#   RUNS       how many times to run the suite          (default 20)
#   RETRIES    reruns of the failed tests per run       (default 2)
#   THRESHOLD  max failures per test over the batch     (default $FLAKINESS_THRESHOLD or 2)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

RUNS="${1:-20}"
RETRIES="${2:-2}"
THRESHOLD="${3:-${FLAKINESS_THRESHOLD:-2}}"
RESULTS_DIR="$SCRIPT_DIR/flakiness-results"
FORMATTERS=(--formatter ExUnit.CLIFormatter --formatter Voyager.E2E.FlakinessFormatter)

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

echo "Benchmarking e2e flakiness: $RUNS run(s) x (1 attempt + $RETRIES retries), threshold=$THRESHOLD"

for i in $(seq 1 "$RUNS"); do
  printf '\n=== Run %d/%d ===\n' "$i" "$RUNS"
  idx="$(printf '%03d' "$i")"
  export FLAKINESS_LOG="$RESULTS_DIR/run-$idx.jsonl"

  # `mix e2e` resets the database and starts fresh target nodes, so runs don't leak state.
  FLAKINESS_ATTEMPT=1 mix e2e "${FORMATTERS[@]}" 2>&1 | tee "$RESULTS_DIR/run-$idx.log"
  rc="${PIPESTATUS[0]}"

  attempt=1
  while [ "$rc" -eq 2 ] && [ "$attempt" -le "$RETRIES" ]; do
    attempt=$((attempt + 1))
    FLAKINESS_ATTEMPT="$attempt" mix e2e --failed "${FORMATTERS[@]}" 2>&1 | tee "$RESULTS_DIR/retry.log" | tee -a "$RESULTS_DIR/run-$idx.log"
    rc="${PIPESTATUS[0]}"
    # `--failed` with no failed tests to run (a failure outside any test, e.g. an on_exit) is a failure.
    if grep -q "There are no tests to run" "$RESULTS_DIR/retry.log"; then break; fi
  done
done

echo
echo "==================================================================="
elixir "$SCRIPT_DIR/aggregate_flakiness.exs" "$RESULTS_DIR" --write --threshold="$THRESHOLD"
