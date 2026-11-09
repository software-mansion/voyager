---
paths:
  - "lib/**"
  - "test/**"
  - "assets/js/**"
---

# Comments

Every rule below comes from a comment a reviewer or author deleted in this repo's history. Write a comment only when the code cannot say it itself: a non-obvious *why*, a workaround, a constraint from OTP/Phoenix/the remote node. **Never** restate *what* the next line does.

**Shape of a comment that survives review**: one line, names the concrete API or failure mode, states the consequence. `# A negative delay raises in Process.send_after/3, and zero ticks in a loop.` Compare the four-line version it replaced: "Only the offered intervals are honoured: a negative value raises in `Process.send_after/3` and a zero would tick in a tight loop." Same fact, half the words.

- **Length**: one or two lines. A comment that needs a paragraph means the code needs a better-named function, not prose. Reviewers cut every 3+ line rationale block in the process list to one line or nothing
- **Density**: a diff that adds more than a handful of `#` lines per file gets re-read with the goal of deleting most of them. One LiveView once shipped with ~100 comment lines; the review commits were literally titled "Reduce comments" and "trim the review fixes down"
- **Say it once**: a constraint gets one comment at the place that owns it, not a restatement at every call site (`# Rate limiting and timeouts are transient…` appeared three times, `# Drop the mount scan so…` five times, `# Same 9 calls as…` four times — all cut)
- **Keep it true**: when you change code, update or delete the comments and docs that describe it
- **Delete** these on sight, do not generate them:
  - section banners and dividers (`# Assigns`, `# Helpers`, `# Private — helpers`, `# ---...---`, `# Mount` / `# Events` / `# Render`, `// Layout` / `// Overlays` / `// Pure helpers`)
  - narration of the obvious (`# Fetch the connection`, `# Wait for epmd daemon to start`, `// Change the cursor to a pointer when hovering`, `// Tear down ones no longer needed.` / `// Create new ones.`)
  - restating a `@spec`, a function name, or a pattern match in prose
  - describing what the rendered UI already shows (`# The header already says Memory`, `# Reads as a link on hover`, `# The title carries the untruncated value`)
  - arithmetic walkthroughs of literals (`# Tick 1: 0.0 + (2 * 0.4) = 0.8 tokens`, `# 10 per page over 30 rows: the 10th row is on page 1`, `# 9 erpc calls: which_applications + …`) — name the constant or restructure the fixture instead
  - tuning tables for magic numbers (`// 0.5 = aggressive boxy S-curve`, `// 0.25 to 0.35 = smooth`) — pick a value, give it a name
  - ASCII-art diagrams of fixture/mock/demo data (a 30-line tree of `<app>_worker_1 … _6` was deleted with the mock it described) — the fixture module is the documentation
  - dev recipes and IEx snippets (`#     Application.put_env(:voyager, :process_list_delay_ms, 2_000)`) — those belong in `README`/docs, never in source
  - commented-out code, whole components commented out with `#`, and generator option menus left as comments (`# {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}`, `//   use: { ...devices['Pixel 5'] }`)
  - `# TODO` left behind after the change is done, and any future-tense status comment (`# will be removed when adding actual logic`, `# This call should not be here, it's temporary`, `# We will move … probably in the future`, `# Redirecting will be available after #41 and #99`)
  - changelog/diff talk (`# Changed from assign_new`, `# New in this PR`, `# Was broken before`, `# The limit is a free integer now, not one of a fixed set`, `# PID is narrow and fixed now`) — "now" has no meaning to the next reader
  - traces of the chat that produced the code (`# As requested`, `# Per your instruction`, `# Fixed the bug you mentioned`, `# Now using streams as suggested`) — the code has no reader who was in that conversation
  - ticket, PR and commit references, and text pasted from the ticket (`# VOY-123`, `# Part of VOY-123`, `# Regression for PR #86 (commit 6304c7b)`, `# See Linear issue`) — issue tracking lives in the commit message and PR, never in source. The only comment that may name an external source is one whose *content* explains a non-obvious constraint (e.g. a link to an upstream OTP bug the workaround exists for)
  - non-English comments
- **Tests**: the test name and the assertion are the documentation. No step narration (`# Select an app`, `# Click refresh`, `# Now change depth`, `# Tree should now be rendered`), no restating the assertion (`# The smallest-N by memory must not exceed the largest-N`), no restating a helper's own contract (`# Both tasks are start_supervised! so they are cleaned up`). The one comment tests may keep is a sync/isolation reason a reader cannot infer (`# async: false because Mox global mode: the scan runs in an async task`) — one line
- **HEEx**: same rules for `<%!-- --%>`. No per-section labels (`<%!-- Header --%>`, `<%!-- Body --%>`, `<%!-- Cookie --%>`), no styling rationale (`<%!-- The zebra stripe already tints alternate rows, so a plain… --%>`) — the class list is the statement. Keep at most a one-liner for an a11y role choice or a `phx-update="ignore"` reason
- **JS hooks**: a hook file gets at most one header line saying what element it drives; no rationale paragraphs above each method
- Prefer a well-named private function or variable over a comment explaining a block
- Public API docs go in `@doc`/`@moduledoc`, not in `#` comments above the function
- When editing existing code, do not add comments to lines you merely touched, and delete any of the above you find in the hunk
