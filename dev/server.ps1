# powershell -ExecutionPolicy Bypass -File dev\server.ps1
# Or once: Set-ExecutionPolicy -Scope CurrentUser Bypass

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

mix compile

$mix_env = if ($env:MIX_ENV) { $env:MIX_ENV } else { "dev" }
$ebin = "$PWD\_build\$mix_env\lib\voyager\ebin"

iex.bat --name voyager_test@127.0.0.1 --cookie test `
  --erl "-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" `
  -S mix phx.server
