# Connecting to a node

Voyager talks to your node over Erlang distribution, the same mechanism `iex --remsh` uses. That means two things must be true before the connect form can do anything:

1. the node is **distributed**: it was started with a name;
2. Voyager knows its **cookie**.

If either is missing the connection fails, usually with a vague "node down" or "connection refused". This guide covers both connection types, what each field means and what to check when it does not work.

## Direct connection

Use this when the node runs on your machine, or on a host you can reach directly on the network (same LAN, VPN).

### Start the node with a name and a cookie

Short names work when Voyager and the node are on the same host, or on hosts that resolve each other by bare hostname:

```sh
iex --sname my_app --cookie my-secret-cookie -S mix phx.server
```

Long names are required when you connect by IP or fully qualified domain name:

```sh
iex --name my_app@127.0.0.1 --cookie my-secret-cookie -S mix phx.server
```

For a Mix release set the equivalent environment variables instead:

```sh
RELEASE_DISTRIBUTION=name RELEASE_NODE=my_app@10.0.0.5 RELEASE_COOKIE=my-secret-cookie bin/my_app start
```

`RELEASE_DISTRIBUTION=sname` gives you short names.

### Fill in the form

- **Node name**: exactly what you passed to `--sname` or `--name`. Short names look like `my_app@my-machine`, long names like `my_app@10.0.0.5` or `my_app@server.company.com`.
- **Short / long toggle** next to the node name: must match how the node was started. A short-named node and a long-named Voyager cannot see each other, even on the same machine.
- **Cookie**: the value of `--cookie` or `RELEASE_COOKIE`. If the node was started without an explicit cookie it uses the one in `~/.erlang.cookie` on its host.
- **Remember cookie**: stores the cookie encrypted in Voyager's local database so the next connect is one click.

## SSH tunnel

Use this for a node behind a firewall or bastion, which is the usual production setup. Voyager opens an SSH session to a host that can reach the node, forwards the distribution port through it, and connects as if the node were local.

### What the remote side needs

- An SSH user that can log in to the host with a password.
- The node must be reachable from that host: same machine, or a host that routes to it.
- `epmd` running on the node's host on its default port (4369) unless you changed it. Voyager asks `epmd` which port the node listens on before opening the tunnel.

### Fill in the form

- **SSH User / SSH Host / SSH Port**: the login you would use with `ssh user@host -p port`.
- **SSH Password**: password authentication only for now; keys are not supported.
- **Node Name**: the node's name as seen *from the SSH host*. For a node on the same machine as the SSH server `my_app@127.0.0.1` is typical.
- **Cookie**: same as for direct connections.
- **EPMD Port**: leave at 4369 unless the node's host runs `epmd` on a different port.

The SSH option is greyed out when Voyager was not started with its `proxy_epmd` module. That is how the local BEAM learns to route distribution traffic through the tunnel; the packaged desktop builds always enable it.

## When it does not connect

- **"Node down" right away**: the node is not distributed, or the name type toggle does not match. Run `node()` in the node's shell; `:nonode@nohost` means no name was given at boot.
- **Connection refused / timeout**: the host or the port is not reachable. For a direct connection check that `epmd` and the distribution port (random by default, see `inet_dist_listen_min` / `inet_dist_listen_max`) are open in the firewall. For SSH check that the SSH host itself can reach the node.
- **Cookie mismatch**: the node logs `** Connection attempt from disallowed node ... **`. Compare the cookie with `:erlang.get_cookie()` on the node.
- **Works from the shell, not from Voyager**: make sure Voyager's own name type (Settings → Distribution) matches the node's. Mixed short and long names never connect.
- **Name resolves differently**: a long name must resolve to the same address from Voyager and from the node. When in doubt use an IP address instead of a hostname.

Recent connections are saved in a local SQLite database; secrets are encrypted before being written with a key that lives only at `~/.voyager/vault.key`.
