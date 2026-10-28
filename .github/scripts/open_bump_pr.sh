#!/usr/bin/env bash
# Opens the bot PR for the .tool-versions change left by bump_elixir_otp.sh and dispatches CI on it.
set -euo pipefail

changelog() {
  echo "Automated bump by the Bump Elixir and OTP workflow."
  for version in $ELIXIR_RELEASES; do
    printf '\n<details><summary>Elixir %s</summary>\n\n' "$version"
    gh api "repos/elixir-lang/elixir/releases/tags/v$version" --jq .body
    printf '\n</details>\n'
  done
  [[ -z $OTP_RELEASES ]] || printf '\n## OTP\n\n'
  for version in $OTP_RELEASES; do
    echo "- [OTP $version](https://github.com/erlang/otp/releases/tag/OTP-$version)"
  done
}

open_pr=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')

if git diff --quiet; then
  echo "Already up to date"
  [[ -z $open_pr ]] || gh pr close "$open_pr" --comment "main already has these versions."
  exit 0
fi

if [[ -n $open_pr ]]; then
  echo "PR #$open_pr is still open"
  exit 0
fi

closed=$(gh pr list --head "$BRANCH" --state closed --limit 100 --json title --jq 'any(.[]; .title == env.TITLE)')
if [[ $closed == true ]]; then
  echo "A PR for these versions was closed without merging"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -c "$BRANCH"
git commit -am "$TITLE"
git push --force origin "$BRANCH"

# PRs opened with GITHUB_TOKEN do not trigger pull_request workflows. Dispatch before creating the PR so a rerun retries it.
for workflow in ci-check.yaml playwright.yml build-apps.yml; do
  gh workflow run "$workflow" --ref "$BRANCH"
done
gh pr create --base main --head "$BRANCH" --title "$TITLE" --body "$(changelog)"
