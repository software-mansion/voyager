#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mix_file="$root_dir/mix.exs"
tauri_conf="$root_dir/rel/app/src-tauri/tauri.conf.json"
cargo_toml="$root_dir/rel/app/src-tauri/Cargo.toml"

mix_version="$(awk -F '"' '/^[[:space:]]*version:[[:space:]]*"/ { print $2; exit }' "$mix_file")"
tauri_version="$(awk -F '"' '/^[[:space:]]*"version"[[:space:]]*:/ { print $4; exit }' "$tauri_conf")"
cargo_version="$(
  awk '
    /^\[package\]/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^[[:space:]]*version[[:space:]]*=/ {
      split($0, parts, "\"")
      print parts[2]
      exit
    }
  ' "$cargo_toml"
)"

if [ -z "$mix_version" ] || [ -z "$tauri_version" ] || [ -z "$cargo_version" ]; then
  echo "Unable to read all application versions." >&2
  echo "mix.exs: ${mix_version:-<missing>}" >&2
  echo "tauri.conf.json: ${tauri_version:-<missing>}" >&2
  echo "Cargo.toml: ${cargo_version:-<missing>}" >&2
  exit 1
fi

status=0

if [ "$tauri_version" != "$mix_version" ]; then
  echo "rel/app/src-tauri/tauri.conf.json: found \"$tauri_version\", expected \"$mix_version\" from mix.exs" >&2
  status=1
fi

if [ "$cargo_version" != "$mix_version" ]; then
  echo "rel/app/src-tauri/Cargo.toml: found \"$cargo_version\", expected \"$mix_version\" from mix.exs" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Version check passed - all files are at $mix_version"
fi

exit "$status"
