#!/usr/bin/env bash
# Usage: ./tauri.sh [command] [options]
#
# This is heavily inspired by: https://github.com/livebook-dev/livebook/blob/6b74cfc835c3000cf0cb9dedf204ea8722863088/rel/app/tauri.sh
# It allows for better dev experience and is used in `tauri-action` to build the app on CI.
#
# Commands:
#
#   build   see: cargo tauri build --help
#   dev     see: cargo tauri dev --help
#   app     build + open app
set -euo pipefail

main() {

  root_dir="$(cd "$(dirname "$0")" && pwd)"
  mix_project_dir="${root_dir}/../.."
  app="Voyager"

  case "$(uname -s)" in
    Darwin*)
      os=darwin
      ;;
    Linux*)
      os=linux
      ;;
  esac

  profile="release"
  for arg in "$@"; do
    if [ "$arg" = "--debug" ]; then
      profile="debug"
      break
    fi
  done

  release_dir="rel-${os}"
  release_root="$root_dir/src-tauri/$release_dir"

  command="${1:-}"

  config="--config"
  # tauri.conf.json keeps resources as an empty list so this per-OS map replaces it.
  config_json="{\"bundle\":{\"resources\":{\"${release_dir}\":\"rel\"}}}"

  if [ -z "${MIX_ENV:-}" ] && [ "$profile" = "release" ] && [ "$command" != "dev" ]; then
    export MIX_ENV="prod"
  fi

  case "$command" in
    dev)
      cargo tauri "$@"
      ;;
    app)
      shift
      mix_release
      bundles_flag=""
      if [ "$os" = "darwin" ]; then
        bundles_flag="--bundles app"
      fi
      tauri_build $bundles_flag "$@"
      open_app "$@"
      ;;
    build)
      shift
      mix_release
      tauri_build "$@"
      ;;
    *)
      cargo tauri "$@"
      ;;
  esac
}

open_app() {
  case "$os" in
    darwin)
      trap 'osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1' INT TERM

      lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      $lsregister -u /Applications/${app}.app || true

      app_path="$root_dir/src-tauri/target/$profile/bundle/macos/${app}.app"
      open -W --stdout "$(tty)" --stderr "$(tty)" "$app_path" --args "$@"
      ;;
  esac
}

mix_release() {
  log "Building Phoenix release at $release_root"
  (
    cd "${mix_project_dir}"
    mix release voyager --overwrite --path "$release_root"
  )
  log "Phoenix release finished"
}

tauri_build() {
  log "Building Tauri app with args: $*"
  cargo tauri build "$config" "$config_json" --verbose "$@"
  log "Tauri build finished"
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

main "$@"
