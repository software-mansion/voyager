# Seeds a single SshConnection row so `recent_connections.spec.ts` can exercise
# the SSH recents/fill-from-recent UI without a real sshd in the e2e harness.
# Run with `MIX_ENV=e2e mix run --no-start e2e/seed_ssh.exs` from the repo root.

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Voyager.Vault.start_link()
{:ok, _} = Voyager.Repo.start_link()

Voyager.Actions.SshConnections.upsert_connected(
  "e2e_ssh_user",
  "bastion.e2e.test",
  22,
  "ssh-test@127.0.0.1",
  cookie: "e2e_ssh_cookie",
  name_type: :longnames,
  auth_method: :agent,
  epmd_port: 4369
)
