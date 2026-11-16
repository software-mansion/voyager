---
paths:
  - "lib/voyager/services/**"
  - "lib/voyager/node_session/**"
  - "lib/voyager/erpc.ex"
  - "lib/voyager/mcp/**"
  - "priv/voyager_agent.erl"
  - "lib/voyager_web/live/**"
---

# Remote nodes

Voyager inspects nodes that may be in production; every call it makes costs the inspected system.

- Remote calls go through `Voyager.Erpc`; handle every `Voyager.Erpc.erpc_error()` variant
- A timeout stops the wait, not the remote work. Bound each call by size or count (rows, bytes,
  depth), not only by time
- One fetch in flight per view: skip or cancel a new fetch while one runs, schedule the next poll
  after the previous one finishes, and ignore refresh/sort events while loading
- Batch lookups into one `:erpc` call instead of one call per item
- Cache expensive remote scans (`code:all_loaded/0` and similar) with a TTL that reflects their
  cost on a busy node
- Data from a remote node is untrusted: arbitrary terms, huge binaries, labels of any size.
  Truncate before rendering, storing or sending to the client
- The Elixir and Erlang term formatters render the same input equivalently (map order,
  charlists, result order)

## Untrusted input in services

- **Never** pass unvalidated host or option strings to `ssh` or `System.cmd`: a value starting
  with `-` becomes an option (`-oProxyCommand`)
- Validate keyword opts against the allowed set (`limit` > 0, `since` >= 0) and handle `nil`
  without raising
- Allowlist metadata fields instead of forwarding everything
- Cap work driven by file or remote data (e.g. bcrypt `rounds` in a key file)
- Fail closed: a read error other than `:enoent` is a failure, not "missing"
