#!/usr/bin/env bash
# Pins .tool-versions to the newest OTP and Elixir builds on builds.hex.pm within the current OTP major.
set -euo pipefail

hex=https://builds.hex.pm/builds
current_otp=$(awk '$1 == "erlang" {print $2}' .tool-versions)
current_elixir=$(awk '$1 == "elixir" {print $2}' .tool-versions)
major=${current_otp%%.*}

otp_versions=$(curl -fsS "$hex/otp/ubuntu-24.04/builds.txt" | awk '{print $1}' |
  sed -nE "s/^OTP-($major(\.[0-9]+)+)$/\1/p" | sort -V)
elixir_versions=$(curl -fsS "$hex/elixir/builds.txt" | awk '{print $1}' |
  sed -nE "s/^v([0-9]+\.[0-9]+\.[0-9]+)-otp-$major$/\1/p" | sort -V)

newer_than() {
  awk -v current="$1" 'found; $0 == current {found = 1}' | paste -sd ' ' -
}

changelog() {
  echo "Automated bump by the Bump Elixir and OTP workflow."
  for version in $elixir_releases; do
    printf '\n<details><summary>Elixir %s</summary>\n\n' "$version"
    gh api "repos/elixir-lang/elixir/releases/tags/v$version" --jq .body
    printf '\n</details>\n'
  done
  [[ -z $otp_releases ]] || printf '\n## OTP\n\n'
  for version in $otp_releases; do
    echo "- [OTP $version](https://github.com/erlang/otp/releases/tag/OTP-$version)"
  done
}

otp_releases=$(newer_than "$current_otp" <<< "$otp_versions")
elixir_releases=$(newer_than "${current_elixir%%-*}" <<< "$elixir_versions")

otp=${otp_releases##* }
otp=${otp:-$current_otp}
elixir=${elixir_releases##* }
elixir=${elixir:+$elixir-otp-$major}
elixir=${elixir:-$current_elixir}

sed -E -e "s/^erlang .*/erlang $otp/" -e "s/^elixir .*/elixir $elixir/" .tool-versions > .tool-versions.tmp
mv .tool-versions.tmp .tool-versions

# Elixir release notes are arbitrary text, so a fixed heredoc delimiter could end the output early.
delimiter=$(openssl rand -hex 16)
{
  echo "otp=$otp"
  echo "elixir=$elixir"
  echo "body<<$delimiter"
  changelog
  echo "$delimiter"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
