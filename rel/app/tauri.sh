#!/usr/bin/env bash
# Usage: ./tauri.sh [command] [options]
#
# Commands:
#   before-build
#   dev     see: cargo tauri dev --help
#   build   see: cargo tauri build --help
set -euo pipefail

main() {
  root_dir="$(cd "$(dirname "$0")" && pwd)"
  mix_project_dir="${root_dir}/../.."
  release_root="${root_dir}/src-tauri/target/rel"

  command="${1:-}"

  case "$command" in
    before-build)
      (
        cd "${mix_project_dir}"
        export MIX_ENV="${MIX_ENV:-prod}"
        mix do compile + assets.deploy + release voyager --overwrite --path "${release_root}"
      )
      ;;

    dev)
      shift
      (
        cd "${root_dir}"
        cargo tauri dev "$@"
      )
      ;;

    build)
      shift
      (
        cd "${root_dir}"
        cargo tauri build "$@"
      )
      ;;

    *)
      (
        cd "${root_dir}"
        cargo tauri "$@"
      )
      ;;
  esac
}

main "$@"
