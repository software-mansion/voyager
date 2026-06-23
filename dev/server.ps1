$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

mix compile

$mix_env = if ($env:MIX_ENV) { $env:MIX_ENV } else { "dev" }
$ebin = "$PWD\_build\$mix_env\lib\voyager\ebin"

iex.bat --erl "-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" `
  -S mix phx.server
