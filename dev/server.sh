#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "${BASH_SOURCE[0]}") [ [--name <node_name> | --sname <node_sname>] --cookie <cookie_secret> ]"
  echo "Options:"
  echo "  --name <node_name>    Start node with a fully qualified name"
  echo "  --sname <node_sname>  Start node with a short name"
  echo "  --cookie <secret>     Set the Erlang distribution cookie"
  exit "${1:-0}"
}

node_name=""
name_flag=""
cookie=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --name|--sname) 
      if [[ "$#" -lt 2 || "$2" == -* ]]; then
        echo "Error: $1 requires a value." >&2
        usage 1
      fi
      name_flag="$1"
      node_name="$2"
      shift 2
      ;;
    --cookie) 
      if [[ "$#" -lt 2 || "$2" == -* ]]; then
        echo "Error: $1 requires a value." >&2
        usage 1
      fi
      cookie="$2"
      shift 2
      ;;
        *) 
      echo "Error: Unknown parameter passed: $1" >&2
      usage 1
      ;;
  esac
done

if [[ ( -n "$node_name" && -z "$cookie" ) || ( -z "$node_name" && -n "$cookie" ) ]]; then
  echo "Error: To enable distribution, you must provide both a name (--name or --sname) AND a --cookie." >&2
  usage 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mix compile

env="${MIX_ENV:-dev}"
ebin="$PWD/_build/$env/lib/voyager/ebin"

iex_args=()

if [[ -n "$node_name" && -n "$cookie" ]]; then
  iex_args+=("$name_flag" "$node_name" "--cookie" "$cookie")
fi

iex_args+=(
  "--erl" "-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" 
  "-S" "mix" "phx.server"
)

exec iex "${iex_args[@]}"
