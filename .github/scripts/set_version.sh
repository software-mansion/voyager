#!/usr/bin/env bash
# Sets the app version in every file that carries it. GNU sed only: use gsed on macOS.
set -euo pipefail

version=$1

sed -i -E "s/^( +version: )\"[^\"]*\"/\1\"$version\"/" mix.exs
sed -i -E "0,/^version = /s/^version = \"[^\"]*\"/version = \"$version\"/" rel/app/src-tauri/Cargo.toml
sed -i -E "s/^(  \"version\": )\"[^\"]*\"/\1\"$version\"/" rel/app/src-tauri/tauri.conf.json
sed -i -E "/^name = \"Voyager\"$/{n;s/^version = .*/version = \"$version\"/}" rel/app/src-tauri/Cargo.lock

dev/tauri_check_version.sh
