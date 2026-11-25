#!/usr/bin/env bash
# Tags a merged release/vX.Y.Z PR and starts release.yml on the tag.
set -euo pipefail

tag=${HEAD_REF#release/}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || { echo "Invalid release tag $tag" >&2; exit 1; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$tag" -m "$tag" "$MERGE_SHA"
git push origin "$tag"

# A tag pushed with GITHUB_TOKEN does not trigger push workflows, but workflow_dispatch is exempt.
gh workflow run release.yml --ref "$tag"
