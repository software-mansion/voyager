#!/usr/bin/env bash
# Usage: ./tauri.sh [command] [options]
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

  release_root="$root_dir/src-tauri/rel-${os}"

  command="${1:-}"

  config="--config"
  config_json="{\"bundle\":{\"resources\":{\"rel-${os}\":\"rel\"}}}"

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
      cargo tauri build "$config" "$config_json" $bundles_flag "$@"
      open_app "$@"
      ;;
    build)
      shift
      mix_release
      cargo tauri build "$config" "$config_json" "$@"
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
  (
    cd "${mix_project_dir}"
    mix release voyager --overwrite --path "$release_root"
  )
}

main "$@"
