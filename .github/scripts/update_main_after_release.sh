#!/usr/bin/env bash
# Moves main to the next minor -dev version and takes CHANGELOG.md from a released tag.
set -euo pipefail

tag=$1
latest=$(git tag -l 'v*' --sort=-v:refname | grep -v -- - | head -1)
# A patch on an older release line must not rewind main.
[[ $tag == "$latest" ]] || { echo "$tag is not the newest final release ($latest)"; exit 0; }
[[ $tag =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || { echo "Invalid release tag $tag" >&2; exit 1; }

git checkout "$tag" -- CHANGELOG.md
bash .github/scripts/set_version.sh "${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0-dev"
