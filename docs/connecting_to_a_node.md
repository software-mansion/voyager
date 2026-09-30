# Connecting to a node

Voyager talks to your node over [Erlang distribution](https://www.erlang.org/doc/system/distributed.html). That means two things must be true before the connect form can do anything:

1. the node is **distributed**: it was started with a [name](https://www.erlang.org/doc/apps/erts/erl_cmd.html#name);
2. Voyager knows its [**cookie**](https://www.erlang.org/doc/system/distributed.html#security).

If either is missing the connection fails. This guide covers both connection types, what each field means and what to check when it does not work.

## Direct connection

Use this when the node runs on your machine, or on a host you can reach directly on the network (same LAN, VPN).

### Start the node with a name and a cookie

[Short names](https://www.erlang.org/doc/apps/erts/erl_cmd.html#sname) work when Voyager and the node are on the same host, or on hosts that resolve each other by bare hostname:

```sh
iex --sname my_app --cookie my-secret-cookie -S mix phx.server
```

[Long names](https://www.erlang.org/doc/apps/erts/erl_cmd.html#name) are required when you connect by IP or fully qualified domain name:

```sh
iex --name my_app@127.0.0.1 --cookie my-secret-cookie -S mix phx.server
```

For a Mix release set the equivalent [environment variables](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-environment-variables) instead:

```sh
RELEASE_DISTRIBUTION=name RELEASE_NODE=my_app@10.0.0.5 RELEASE_COOKIE=my-secret-cookie bin/my_app start
```

`RELEASE_DISTRIBUTION=sname` gives you short names.

### Fill in the form

- **Node name**: exactly what you passed to `--sname` or `--name`. Short names look like `my_app@my-machine`, long names like `my_app@10.0.0.5` or `my_app@server.company.com`.
- **Short / long toggle** next to the node name: must match how the node was started. A short-named node and a long-named Voyager cannot see each other, even on the same machine.
- **Cookie**: the value of [`--cookie`](https://www.erlang.org/doc/apps/erts/erl_cmd.html#setcookie) or `RELEASE_COOKIE`. If the node was started without an explicit cookie it uses the one in `~/.erlang.cookie` on its host.
- **Remember cookie**: stores the cookie encrypted in Voyager's local database so the next connect is one click.

## SSH tunnel

Use this for a node behind a firewall or bastion, which is the usual production setup. Voyager opens an SSH session to a host that can reach the node, forwards the distribution port through it, and connects as if the node were local.

### What the remote side needs

- An SSH login to the host: either a key loaded in your local SSH agent, or a password.
- The node must be reachable from that host: same machine, or a host that routes to it.
- [`epmd`](https://www.erlang.org/doc/apps/erts/epmd_cmd.html) running on the node's host (default port 4369). Voyager asks `epmd` which port the node listens on before opening the tunnel.

### Fill in the form

- **SSH User / SSH Host**: the login you would use with `ssh user@host`.
- **Node Name**: the node's name as seen *from the SSH host*. For a node on the same machine as the SSH server `my_app@127.0.0.1` is typical.
- **Cookie**: same as for direct connections.
- **Authentication**: **SSH Agent** (default) uses the keys your local `ssh-agent` already holds. One catch: Erlang's [SSH agent client](https://www.erlang.org/doc/apps/ssh/ssh_agent.html) asks the agent for a single key per key type and tries only the first one it gets, so with two ed25519 keys loaded only the one added first is ever offered. If the host wants the other one, load it alone (`ssh-add -D`, then `ssh-add ~/.ssh/that_key`) or use a different key type for it. **Password** asks for the account password instead and can remember it encrypted.
- **Advanced**: **SSH Port** (default 22) and **EPMD Port** (default 4369). Change them only when the host runs SSH or `epmd` on a non-standard port.

The SSH option is greyed out when Voyager was not started with its `proxy_epmd` module. That is how the local BEAM learns to route distribution traffic through the tunnel; the packaged desktop builds always enable it.

## When it does not connect

- **"Node down" right away**: the node is not distributed, or the name type toggle does not match. Run `node()` in the node's shell; `:nonode@nohost` means no name was given at boot.
- **Connection refused / timeout**: the host or the port is not reachable. For a direct connection check that `epmd` (4369) and the distribution port (random by default, you can pin it with [`inet_dist_listen_min` / `inet_dist_listen_max`](https://www.erlang.org/doc/apps/kernel/kernel_app.html#inet_dist_listen)) are open in the firewall. For SSH check that the SSH host itself can reach the node.
- **"SSH authentication failed"**: with SSH Agent, check that `ssh-add -l` lists a key the host accepts and that the agent is running. If it lists several keys of the same type, only the first is tried; see the Authentication note above. With Password, check the password. Try `ssh user@host` from a terminal first.
- **Cookie mismatch**: the node logs `** Connection attempt from disallowed node ... **`. Compare the cookie with [`:erlang.get_cookie()`](https://www.erlang.org/doc/apps/erts/erlang.html#get_cookie/0) on the node.
- **Name resolves differently**: a long name must resolve to the same address from Voyager and from the node. When in doubt use an IP address instead of a hostname.

