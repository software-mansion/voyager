---
paths:
  - ".github/**"
  - "mix.exs"
  - "rel/**"
  - "dev/**"
  - "config/**"
---

# CI, scripts and release

- Keep action versions consistent across `.github/workflows/`
- Move a long inline `run:` block to `.github/scripts/*.sh`
- `mix.exs` aliases: no duplicate steps in `precommit` / `format`; formatting runs before tests
- The versions in `rel/app/src-tauri/tauri.conf.json` and `mix.exs` change together
  (`dev/tauri_check_version.sh` checks it)
- Bash with `set -u`: every variable is set on every `case` branch; check a flag has a value
  before `shift 2`
- A setting the UI changes at runtime never goes in `config :voyager` in `config.exs`; that locks
  it
- Docs point at `.tool-versions` instead of repeating versions
- Don't commit lockfile changes or edits unrelated to the PR
