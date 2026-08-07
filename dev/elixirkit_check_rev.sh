#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mix_lock="$root_dir/mix.lock"
cargo_toml="$root_dir/rel/app/src-tauri/Cargo.toml"
cargo_lock="$root_dir/rel/app/src-tauri/Cargo.lock"

mix_rev="$(
  sed -n 's/.*"elixirkit": {:git, "[^"]*", "\([^"]*\)".*/\1/p' "$mix_lock" | head -n1
)"

cargo_toml_rev="$(
  awk '
    /^[[:space:]]*elixirkit[[:space:]]*=/ {
      if (match($0, /rev[[:space:]]*=[[:space:]]*"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^rev[[:space:]]*=[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' "$cargo_toml"
)"

cargo_lock_rev="$(
  awk '
    /^name = "elixirkit"$/ { in_pkg = 1; next }
    in_pkg && /^\[\[package\]\]/ { in_pkg = 0 }
    in_pkg && /^source = / {
      if (match($0, /rev=[0-9a-f]+/)) {
        print substr($0, RSTART + 4, RLENGTH - 4)
        exit
      }
      if (match($0, /#[0-9a-f]+"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ' "$cargo_lock"
)"

if [ -z "$mix_rev" ] || [ -z "$cargo_toml_rev" ] || [ -z "$cargo_lock_rev" ]; then
  echo "Unable to read all ElixirKit git revisions." >&2
  echo "mix.lock: ${mix_rev:-<missing>}" >&2
  echo "Cargo.toml: ${cargo_toml_rev:-<missing>}" >&2
  echo "Cargo.lock: ${cargo_lock_rev:-<missing>}" >&2
  exit 1
fi

status=0

if [ "$cargo_toml_rev" != "$mix_rev" ]; then
  echo "rel/app/src-tauri/Cargo.toml: found \"$cargo_toml_rev\", expected \"$mix_rev\" from mix.lock" >&2
  status=1
fi

if [ "$cargo_lock_rev" != "$mix_rev" ]; then
  echo "rel/app/src-tauri/Cargo.lock: found \"$cargo_lock_rev\", expected \"$mix_rev\" from mix.lock" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ElixirKit rev check passed - all files are at $mix_rev"
fi

exit "$status"
