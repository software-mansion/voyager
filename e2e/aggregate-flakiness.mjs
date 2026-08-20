// Aggregate per-run Playwright JSON reports into a per-test flakiness report.
//
// Reads every run-*.json in the given directory (default: ./flakiness-results),
// then for each test reports how it behaved across the whole batch:
//
//   runs     runs in which the test actually executed (skips excluded)
//   pass     runs it passed cleanly on the first attempt
//   flaky    runs it failed then passed within --retries (Playwright "flaky")
//   fail     runs it never passed, even after retries ("unexpected")
//   failures flaky + fail  -> runs that were NOT a clean first-attempt pass
//   score    failures / runs
//
// A test that always fails is broken (score 1.0, fail = runs); a test that
// intermittently needs retries is the flaky one to hunt (0 < score < 1).
//
// Usage:
//   node aggregate-flakiness.mjs [results-dir] [--write] [--threshold=N]
//
//   --write         also write summary.txt + summary.json into results-dir,
//                   append a report to $GITHUB_STEP_SUMMARY, and emit GitHub
//                   workflow annotations (::error:: / ::warning::).
//   --threshold=N   exit 1 if any test's `failures` count is greater than N
//                   (default: no threshold -> always exit 0). Use this on the
//                   final aggregation so CI fails when a test is too flaky.

import {
  readFileSync,
  readdirSync,
  writeFileSync,
  appendFileSync,
} from 'node:fs';
import { join } from 'node:path';

// ---- args -----------------------------------------------------------------

let dir;
let write = false;
let threshold = null;
for (const a of process.argv.slice(2)) {
  if (a === '--write') write = true;
  else if (a.startsWith('--threshold=')) {
    const raw = a.slice('--threshold='.length);
    const n = Number(raw);
    if (!Number.isFinite(n) || n < 0) {
      console.error(`❗Invalid --threshold value: ${raw}\n`);
      continue;
    }
    threshold = n;
  } else if (!a.startsWith('--')) dir = a;
}
dir ||= join(process.cwd(), 'flakiness-results');

const files = readdirSync(dir)
  .filter((f) => f.startsWith('run-') && f.endsWith('.json'))
  .sort();

if (files.length === 0) {
  console.error(`❗No run-*.json reports found in ${dir}`);
  process.exit(1);
}

// ---- aggregation ----------------------------------------------------------

const stats = new Map(); // key -> stats

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
const brokenReports = [];

for (const file of files) {
  let report;
  try {
    report = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  } catch (e) {
    console.error(`  ❗skipping unreadable report ${file}: ${e.message}`);
    brokenReports.push(file);
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
    const failures = s.flaky + s.fail;
    const score = s.runs ? failures / s.runs : 0;
    return { ...s, failures, score };
  })
  // Worst first: highest score, then most flaky, then most failed.
  .sort((a, b) => b.score - a.score || b.flaky - a.flaky || b.fail - a.fail);

const flakyRows = rows.filter((r) => r.failures > 0);
const breached =
  threshold === null ? [] : rows.filter((r) => r.failures > threshold);

const totalAttempts = rows.reduce((n, r) => n + r.attempts, 0);
const failedAttempts = rows.reduce((n, r) => n + r.failedAttempts, 0);
const attemptFailRate = totalAttempts ? failedAttempts / totalAttempts : 0;

// ---- human-readable report (stdout + summary.txt) -------------------------

function pad(s, n) {
  return String(s).padEnd(n);
}

function buildReport() {
  const L = [];
  L.push(`Aggregated ${totalRuns} run(s) across ${rows.length} test(s).`);
  if (brokenReports.length) {
    L.push(`Unreadable reports skipped: ${brokenReports.join(', ')}`);
  }
  L.push('');

  if (flakyRows.length === 0) {
    L.push('No flaky or failing tests detected across the batch. 🎉');
  } else {
    const header =
      pad('SCORE', 7) +
      pad('PASS', 6) +
      pad('FLAKY', 7) +
      pad('FAIL', 6) +
      pad('RUNS', 6) +
      'TEST';
    L.push(header);
    L.push('-'.repeat(header.length));
    for (const r of flakyRows) {
      L.push(
        pad(r.score.toFixed(2), 7) +
          pad(String(r.pass), 6) +
          pad(String(r.flaky), 7) +
          pad(String(r.fail), 6) +
          pad(String(r.runs), 6) +
          r.label
      );
    }
  }

  L.push('');
  L.push('Summary');
  L.push(`  runs:              ${totalRuns}`);
  L.push(`  tests tracked:     ${rows.length}`);
  L.push(`  flaky/failing:     ${flakyRows.length}`);
  L.push(
    `  attempt failure:   ${failedAttempts}/${totalAttempts} (${(attemptFailRate * 100).toFixed(2)}%)`
  );
  if (threshold !== null) {
    L.push(`  threshold:         ${threshold} failure(s) per test`);
    L.push(`  over threshold:    ${breached.length} test(s)`);
  }
  return L.join('\n');
}

const report = buildReport();
console.log(report);

// ---- machine-readable + CI outputs ----------------------------------------

if (write) {
  const summaryJson = {
    runs: totalRuns,
    testsTracked: rows.length,
    flakyOrFailing: flakyRows.length,
    totalAttempts,
    failedAttempts,
    attemptFailRate,
    threshold,
    overThreshold: breached.length,
    unreadableReports: brokenReports,
    tests: rows.map((r) => ({
      test: r.label,
      runs: r.runs,
      pass: r.pass,
      flaky: r.flaky,
      fail: r.fail,
      failures: r.failures,
      attempts: r.attempts,
      failedAttempts: r.failedAttempts,
      score: Number(r.score.toFixed(4)),
    })),
    breached: breached.map((r) => r.label),
  };

  writeFileSync(join(dir, 'summary.txt'), report + '\n');
  writeFileSync(
    join(dir, 'summary.json'),
    JSON.stringify(summaryJson, null, 2) + '\n'
  );

  // GitHub Actions job summary (rendered as markdown on the run page).
  if (process.env.GITHUB_STEP_SUMMARY) {
    const md = [];
    md.push('## E2E flakiness benchmark');
    md.push('');
    md.push(
      `**${totalRuns}** runs · **${rows.length}** tests tracked · ` +
        `**${flakyRows.length}** flaky/failing · ` +
        `attempt failure **${(attemptFailRate * 100).toFixed(2)}%**` +
        (threshold !== null
          ? ` · threshold **${threshold}** · over **${breached.length}**`
          : '')
    );
    md.push('');
    if (flakyRows.length === 0) {
      md.push('✅ No flaky or failing tests detected.');
    } else {
      md.push('| Score | Pass | Flaky | Fail | Runs | Test |');
      md.push('| ----: | ---: | ----: | ---: | ---: | :--- |');
      for (const r of flakyRows) {
        const mark = threshold !== null && r.failures > threshold ? ' 🔴' : '';
        md.push(
          `| ${r.score.toFixed(2)} | ${r.pass} | ${r.flaky} | ${r.fail} | ${r.runs} | \`${r.label}\`${mark} |`
        );
      }
    }
    md.push('');
    try {
      appendFileSync(process.env.GITHUB_STEP_SUMMARY, md.join('\n') + '\n');
    } catch (e) {
      console.error(`❗Could not write GITHUB_STEP_SUMMARY: ${e.message}`);
    }
  }

  // Workflow annotations (surface in the run's "Annotations" section).
  if (threshold !== null) {
    for (const r of breached) {
      console.log(
        `::error title=Flaky e2e test::${r.label} — ${r.failures}/${r.runs} runs not a clean pass (threshold ${threshold})`
      );
    }
  }
}

// ---- exit code ------------------------------------------------------------

if (threshold !== null && breached.length > 0) {
  console.log(
    `::error::E2E flakiness benchmark failed: ${breached.length} test(s) exceeded the threshold of ${threshold} failure(s) over ${totalRuns} runs.`
  );
  process.exit(1);
}

if (write && threshold !== null && flakyRows.length > 0) {
  console.log(
    `::warning::${flakyRows.length} flaky/failing test(s) observed but within the threshold of ${threshold}.`
  );
}
