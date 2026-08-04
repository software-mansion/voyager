// Aggregate per-run Playwright JSON reports into a per-test flakiness report.
//
// Reads every run-*.json in the given directory (default: ./flakiness-results),
// then for each test reports how it behaved across the whole batch:
//
//   runs     runs in which the test actually executed (skips excluded)
//   pass     runs it passed cleanly on the first attempt
//   flaky    runs it failed then passed within --retries (Playwright "flaky")
//   fail     runs it never passed, even after retries ("unexpected")
//   score    (flaky + fail) / runs  -> share of runs that were NOT a clean pass
//
// A test that always fails is broken (score 1.0, fail = runs); a test that
// intermittently needs retries is the flaky one to hunt (0 < score < 1).
//
// Usage: node aggregate-flakiness.mjs [results-dir]

import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || join(process.cwd(), 'flakiness-results');

const files = readdirSync(dir)
  .filter((f) => f.startsWith('run-') && f.endsWith('.json'))
  .sort();

if (files.length === 0) {
  console.error(`No run-*.json reports found in ${dir}`);
  process.exit(1);
}

// key -> stats
const stats = new Map();

function ensure(key, label) {
  if (!stats.has(key)) {
    stats.set(key, {
      label,
      runs: 0,
      pass: 0,
      flaky: 0,
      fail: 0,
      attempts: 0,
      failedAttempts: 0,
    });
  }
  return stats.get(key);
}

// Walk the recursive suites/specs/tests tree of a single run report.
// `path` accumulates describe-block titles so tests that share a title under
// different describe blocks stay distinct. The stable, unique key is the
// spec `id` (Playwright derives it from project+file+title path) plus project.
function walk(suite, path, out) {
  const nextPath = suite.title ? [...path, suite.title] : path;
  for (const spec of suite.specs || []) {
    for (const test of spec.tests || []) {
      const project = test.projectName || test.projectId || '?';
      const label = `${[...nextPath, spec.title].join(' › ')} [${project}]`;
      out.push({
        key: `${project}::${spec.id ?? label}`,
        label,
        status: test.status, // expected | unexpected | flaky | skipped
        results: test.results || [],
      });
    }
  }
  for (const child of suite.suites || []) walk(child, nextPath, out);
}

let totalRuns = 0;

for (const file of files) {
  let report;
  try {
    report = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  } catch (e) {
    console.error(`  skipping unreadable report ${file}: ${e.message}`);
    continue;
  }
  totalRuns++;

  const tests = [];
  for (const suite of report.suites || []) walk(suite, [], tests);

  for (const t of tests) {
    if (t.status === 'skipped') continue;
    const s = ensure(t.key, t.label);
    s.runs++;
    if (t.status === 'flaky') s.flaky++;
    else if (t.status === 'expected') s.pass++;
    else s.fail++; // unexpected / anything else

    for (const r of t.results) {
      s.attempts++;
      if (r.status !== 'passed' && r.status !== 'skipped') s.failedAttempts++;
    }
  }
}

const rows = [...stats.values()]
  .map((s) => {
    const score = s.runs ? (s.flaky + s.fail) / s.runs : 0;
    return { ...s, score };
  })
  // Worst first: highest score, then most flaky, then most failed.
  .sort((a, b) => b.score - a.score || b.flaky - a.flaky || b.fail - a.fail);

const flakyRows = rows.filter((r) => r.flaky > 0 || r.fail > 0);

console.log(`Aggregated ${totalRuns} run(s) across ${rows.length} test(s).\n`);

if (flakyRows.length === 0) {
  console.log('No flaky or failing tests detected across the batch. 🎉');
} else {
  const header =
    pad('SCORE', 7) +
    pad('PASS', 6) +
    pad('FLAKY', 7) +
    pad('FAIL', 6) +
    pad('RUNS', 6) +
    'TEST';
  console.log(header);
  console.log('-'.repeat(header.length));
  for (const r of flakyRows) {
    console.log(
      pad(r.score.toFixed(2), 7) +
        pad(String(r.pass), 6) +
        pad(String(r.flaky), 7) +
        pad(String(r.fail), 6) +
        pad(String(r.runs), 6) +
        r.label
    );
  }
}

// Overall attempt-level summary — a single flakiness number for the whole suite.
const totalAttempts = rows.reduce((n, r) => n + r.attempts, 0);
const failedAttempts = rows.reduce((n, r) => n + r.failedAttempts, 0);
const attemptFailRate = totalAttempts ? failedAttempts / totalAttempts : 0;

console.log('\nSummary');
console.log(`  runs:              ${totalRuns}`);
console.log(`  tests tracked:     ${rows.length}`);
console.log(`  flaky/failing:     ${flakyRows.length}`);
console.log(
  `  attempt failure:   ${failedAttempts}/${totalAttempts} (${(attemptFailRate * 100).toFixed(2)}%)`
);

function pad(s, n) {
  return String(s).padEnd(n);
}
