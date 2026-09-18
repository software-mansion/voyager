#!/usr/bin/env bash
# Builds the updater manifest from the release's signature assets and uploads it
# as latest.json. Runs once after every platform job, so the matrix jobs do not
# overwrite each other's entries.
set -euo pipefail

tag="$1"
repo="${GITHUB_REPOSITORY:?}"

platforms="{}"
for sig in $(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name | select(endswith(".sig"))'); do
  archive="${sig%.sig}"
  case "$archive" in
    *-darwin-aarch64*) platform="darwin-aarch64" ;;
    *-darwin-x64*) platform="darwin-x86_64" ;;
    *-linux-amd64*) platform="linux-x86_64" ;;
    *-linux-arm64*) platform="linux-aarch64" ;;
    *) echo "unknown platform in asset name: $archive" >&2; exit 1 ;;
  esac

  gh release download "$tag" --repo "$repo" --pattern "$sig" --output signature.txt --clobber
  platforms="$(
    jq --arg platform "$platform" \
      --arg url "https://github.com/$repo/releases/download/$tag/$archive" \
      --rawfile signature signature.txt \
      '.[$platform] = {url: $url, signature: ($signature | rtrimstr("\n"))}' <<<"$platforms"
  )"
done

if [ "$platforms" = "{}" ]; then
  echo "no .sig assets on release $tag, was TAURI_SIGNING_PRIVATE_KEY set?" >&2
  exit 1
fi

jq -n --arg version "${tag#v}" --arg pub_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson platforms "$platforms" \
  '{version: $version, pub_date: $pub_date, platforms: $platforms}' > latest.json

cat latest.json
gh release upload "$tag" latest.json --repo "$repo" --clobber
