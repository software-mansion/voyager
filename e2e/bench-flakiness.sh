#!/usr/bin/env bash
#
# Benchmark e2e test flakiness.
#
# Runs the full Playwright suite N times, each time with --retries so Playwright
# classifies tests that fail-then-pass as "flaky". Per run it emits:
#   - a JSON report  (run-XXX.json) -> aggregated into a per-test flakiness report
#   - a blob report  (blobs/run-XXX.zip) -> merged into one browsable HTML report
#                                            that embeds traces of failed tests
#   - a raw log      (run-XXX.log)  -> stdout/stderr of that run for debugging
#
# After all runs it merges the blobs into flakiness-results/html-report/ and runs
# the aggregator, which writes summary.txt / summary.json and (in CI) a job
# summary + annotations. If any test's failure count exceeds THRESHOLD the final
# aggregation exits non-zero so the CI job fails (and GitHub notifies); otherwise
# it exits 0 and the benchmark passes silently.
#
# The suite cannot be parallelized (project dependency chain + shared node state),
# so runs are strictly sequential. A fresh mock node is started per run for
# isolated, comparable state. A failing suite never aborts the batch.
#
# Usage:
#   ./bench-flakiness.sh [RUNS] [RETRIES] [THRESHOLD]
#
#   RUNS       how many times to run the full suite     (default 20)
#   RETRIES    Playwright --retries per run              (default 2)
#   THRESHOLD  max allowed failures (flaky+fail) per     (default $FLAKINESS_THRESHOLD or 2)
#              test across the whole batch before the
#              benchmark is considered failed
#
# Example:
#   ./bench-flakiness.sh 30 2 2
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RUNS="${1:-20}"
RETRIES="${2:-2}"
THRESHOLD="${3:-${FLAKINESS_THRESHOLD:-2}}"

RESULTS_DIR="$SCRIPT_DIR/flakiness-results"
BLOBS_DIR="$RESULTS_DIR/blobs"
HTML_DIR="$RESULTS_DIR/html-report"

rm -rf "$RESULTS_DIR"
mkdir -p "$BLOBS_DIR"

# Always leave the machine clean, even on Ctrl-C.
trap 'bash "$SCRIPT_DIR/node.sh" stop >/dev/null 2>&1 || true' EXIT

echo "Benchmarking e2e flakiness: $RUNS run(s) x (1 attempt + $RETRIES retries), threshold=$THRESHOLD"
echo "Results -> $RESULTS_DIR"

for i in $(seq 1 "$RUNS"); do
  printf '\n=== Run %d/%d ===\n' "$i" "$RUNS"
  idx="$(printf '%03d' "$i")"
  run_json="$RESULTS_DIR/run-$idx.json"
  run_log="$RESULTS_DIR/run-$idx.log"
  run_blob="$BLOBS_DIR/run-$idx.zip"

  # Fresh target node each run so state mutations don't leak between runs.
  bash "$SCRIPT_DIR/node.sh" start >/dev/null 2>&1

  # blob  -> rich, mergeable report; embeds traces of failed tests
  # json  -> machine report consumed by aggregate-flakiness.mjs
  # Phoenix is started/reused by Playwright's webServer config.
  # `|| true` keeps a failing suite from killing the batch — a fail is data.
  PLAYWRIGHT_JSON_OUTPUT_FILE="$run_json" \
  PLAYWRIGHT_BLOB_OUTPUT_FILE="$run_blob" \
    npx playwright test --quiet --retries="$RETRIES" --reporter=blob,json \
    2>&1 | tee "$run_log" || true

  bash "$SCRIPT_DIR/node.sh" stop >/dev/null 2>&1

  if [ -f "$run_json" ]; then
    echo "report: $run_json"
    node "$SCRIPT_DIR/aggregate-flakiness.mjs" "$RESULTS_DIR"
  else
    echo "  WARNING: no JSON report produced (see $run_log)"
  fi
done

# Merge all per-run blobs into a single browsable HTML report (with traces).
echo
if ls "$BLOBS_DIR"/*.zip >/dev/null 2>&1; then
  echo "Merging Playwright reports into $HTML_DIR ..."
  if PLAYWRIGHT_HTML_OUTPUT_DIR="$HTML_DIR" PLAYWRIGHT_HTML_OPEN=never \
    npx playwright merge-reports --reporter html "$BLOBS_DIR" \
    >"$RESULTS_DIR/merge.log" 2>&1; then
    echo "  HTML report -> $HTML_DIR"
  else
    echo "  WARNING: merge-reports failed (see $RESULTS_DIR/merge.log)"
  fi
  # Keep only the per-run blob zips (the durable, re-mergeable artifact); drop
  # the reporter's staging leftovers (report.jsonl, resources/) to trim size.
  find "$BLOBS_DIR" -mindepth 1 -maxdepth 1 ! -name 'run-*.zip' -exec rm -rf {} +
else
  echo "No blob reports to merge."
fi

echo
echo "==================================================================="
# Final aggregation: write summary files, emit CI outputs, and enforce the
# threshold. This is the last command, so its exit code is the script's:
# non-zero (threshold breached) fails the CI job; zero passes silently.
node "$SCRIPT_DIR/aggregate-flakiness.mjs" "$RESULTS_DIR" --write --threshold="$THRESHOLD"
