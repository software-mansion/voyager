#!/usr/bin/env bash
# Commits the working-tree changes to $BRANCH, dispatches CI on it and opens a bot PR into $BASE.
set -euo pipefail

open_pr=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')

if git diff --quiet; then
  echo "Already up to date"
  [[ -z $open_pr ]] || gh pr close "$open_pr" --comment "$BASE already has these changes."
  exit 0
fi

if [[ -n $open_pr ]]; then
  echo "PR #$open_pr is still open"
  exit 0
fi

closed=$(gh pr list --head "$BRANCH" --state closed --limit 100 --json title --jq 'any(.[]; .title == env.TITLE)')
if [[ $closed == true ]]; then
  echo "A PR titled \"$TITLE\" was closed without merging"
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
gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY"
