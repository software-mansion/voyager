#!/usr/bin/env bash
# Creates the draft release for a tag, with its CHANGELOG.md section as the notes.
set -euo pipefail

tag=$1
prerelease=()
[[ $tag != *-* ]] || prerelease=(--prerelease)

# An exact match on the version field, so "## 0.2.0" does not pick up "## 0.2.0-rc.1 (2026-10-07)".
awk -v version="${tag#v}" '$1 == "##" { if (found) exit; found = ($2 == version) } found' CHANGELOG.md > notes.md
[[ -s notes.md ]] || { echo "No CHANGELOG.md section for $tag" >&2; exit 1; }

gh release create "$tag" \
  --repo "$GITHUB_REPOSITORY" \
  --title "$tag" \
  --draft \
  "${prerelease[@]}" \
  --notes-file notes.md
