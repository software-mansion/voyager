# ETS peek harness

Manual test harness for the ETS records API — `Voyager.Services.Ets.Remote`,
`Voyager.Services.Ets.Fetch` and `Voyager.Services.Ets.Sanitize`.

```sh
epmd -daemon
MIX_ENV=test mix run dev/ets_peek/peek_matrix.exs
```

The script starts a real peer node with `:peer`, so record payloads and
`:ets.select/3` continuations actually cross external term format. `Node.self()`
tests cannot exercise that: a continuation stays valid when it never leaves the
VM, and a payload that is only referenced rather than copied never reaches the
host heap.

It covers:

- **Table options** — `set` / `ordered_set` / `bag` / `duplicate_bag` across
  `public` / `protected` / `private`, named and unnamed, `keypos` 1–3,
  `compressed`, `read_concurrency`, `write_concurrency` `true | false | :auto`
  and `decentralized_counters`, each read back through `info/3` and `list/2`.
- **Records** — first page per table type, end-of-table continuations, error
  handles (deleted, private, wrong type), limit and key validation.
- **Paging** — that MFA refuses a continuation, that repairing one and selecting
  in two separate remote calls still fails, and that a full drain of each table
  type returns every row exactly once.
- **Host bounds** — what a wide row and a large binary cost the Voyager VM on
  the MFA path, and the same rows with an agent truncating on the target.
- **Cost** — the per-read breakdown between the export probe, the read itself,
  and the task plus sanitizer.

A stand-in `:voyager_agent` implementing the VOY-230 contract (one-shot worker,
bounded heap, target-side truncate to 512 / 50 / 5,
`repair_continuation/2` + `select/1` in one call) is compiled and loaded onto the
peer, so the agent path can be exercised before that module exists. It is a test
double, not a reference implementation.
