---
name: changelog
description: Generate the next CHANGELOG.md section from merged PRs since the last release tag. Use when the user asks to update the changelog, write release notes, or prepare a release. Filters out chores/deps/CI/internal PRs, verifies ambiguous PR titles against the actual diff, and prepends a section matching the existing CHANGELOG.md format.
---

# Changelog generation

Generate the changelog section for a release from git history, in the same format as the existing `CHANGELOG.md`.

## Workflow

1. **Determine the range and date.**
   - Target is an existing tag: prev = `git describe --tags --abbrev=0 <target>^`;
     date = `git for-each-ref --format='%(creatordate:short)' refs/tags/<target>`
   - Target is untagged HEAD (upcoming release): prev = `git describe --tags --abbrev=0`;
     date = the intended release date (default: today)
   - Range is `<prev>..<target>`; the user-named version is the section heading
2. **Collect entries.** `git log <range> --oneline` — one entry per merged PR (`(#N)` suffix).
3. **Filter.** Drop entirely:
   - dependabot / dependency bumps (`Chore: Bump ...`)
   - CI, workflows, review tooling, repo hygiene (CLAUDE.md, README, banners, dependabot config)
   - tests-only and docs-only PRs
   - refactors and internal APIs with no user-visible behavior (e.g. `Add X API`, `Refactor Y`) — when such a PR is groundwork for a feature PR in the same range, the feature entry may cite both PR numbers
   - release-commit itself, lockfile-only fixes
4. **Verify before wording — never guess from a title.** Titles lie ("add zooming" could be pinch, keyboard, or menu). For any entry where the title alone doesn't tell you what the user gets:
   - `gh pr view <N> --json title,body` — many bodies are empty, then:
   - `git show <sha>` and read the diff enough to state the behavior precisely
   - If still unclear, keep the PR title verbatim rather than embellish. Wrong specifics are worse than dry ones.
5. **Word the entries.** Strict mode:
   - Stay close to the PR title; strip the `Feature:`/`Fix:`/`Chore:` prefix
   - Only expand when the diff confirms the specifics (e.g. "Zoom In / Zoom Out menu actions (Cmd+= / Cmd+-)" after reading the accelerators in the diff)
   - Never invent capabilities, platforms, or gestures not in the diff
6. **Group and format — match the existing `CHANGELOG.md`.** Read the top section of the current file and copy its exact conventions: heading style, section names, entry syntax, link style. Do not introduce a new format.
7. **Output.** Prepend the new section to `CHANGELOG.md`, show the result to the user for review. Do not commit or tag.

## Voyager specifics

- PR links: `[#N](https://github.com/software-mansion/voyager/pull/N)`
- Security-relevant fixes (cookies, network binding, distribution exposure) are worth their own precise wording — read those diffs fully
- Early releases with no per-PR notes (e.g. 0.1.0 "Closed Alpha release") keep exactly the text of their GitHub release — do not back-fill invented entries
