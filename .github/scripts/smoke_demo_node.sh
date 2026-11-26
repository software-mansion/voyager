#!/usr/bin/env bash
# Boots the assembled release headless and checks that DemoNode starts the bundled demo node.
set -euo pipefail

release_root="${1:?usage: smoke_demo_node.sh <release root>}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export DATABASE_PATH="$tmp_dir/voyager.db"
SECRET_KEY_BASE="$(openssl rand -base64 48)"
VOYAGER_VAULT_KEY="$(openssl rand -base64 32)"
export SECRET_KEY_BASE VOYAGER_VAULT_KEY

"$release_root/bin/voyager" eval '
{:ok, _apps} = Application.ensure_all_started(:voyager)
{:ok, _params} = Voyager.Services.DemoNode.start()
peer = :sys.get_state(Voyager.Services.DemoNode).peer
true = List.keymember?(:peer.call(peer, :application, :which_applications, []), :supervision_tree_demo, 0)
true = is_reference(:peer.call(peer, :ets, :whereis, [:kv_set]))
IO.puts("Demo node started from the release")
'
