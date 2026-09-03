# ProcessTerm API — memory / DoS assessment (PR #213)

**Target:** `Voyager.Services.ProcessTerm` and the `voyager_agent` term‑bounding
logic added in [PR #213](https://github.com/software-mansion/voyager/pull/213)
("Add ProcessTerm API"), head commit `ef80729`.
**Surfaces exercised:** `voyager_agent:proc_dictionary/3`, `proc_messages/3`,
`proc_label/2`, `proc_state/3` (the functions behind
`ProcessTerm.fetch_state/4`, `ProcessTerm.fetch_messages/5`,
`ProcessInfo.fetch_dictionary/5`, `ProcessInfo.fetch_label/4`).
**Environment:** Erlang/OTP 29 (erts‑17.0.2, JIT), Elixir 1.20.2, 4 vCPU, 16 GB.
**Verdict:** **The term budget does not bound the memory or CPU cost of a fetch.**
A single fetch aimed at one ordinary process can spike the *observed* node's
memory by 100×–1000× that process's real footprint, and on a memory‑ or
CPU‑constrained node a single fetch **crashes or freezes the whole node**. This
was reproduced as an actual `erl_crash.dump` and a 314 ms full‑node stall.

---

## 1. What the code intends

The API is explicitly designed to be safe to point at arbitrarily large process
terms. From `lib/voyager/services/process_term.ex`:

> Neither a rate limit nor a timeout bounds a *payload* — a state or a mailbox
> can be gigabytes — so both go through `:voyager_agent`, which rewrites the term
> on the remote to fit a `budget` **before it crosses the distribution channel**.
> … The agent's `max_heap_size` cap is what keeps a pathological mailbox from
> taking the remote node down.

So there are two claimed protections:

1. **`budget`** (default `5_000`) — `walk/3` in `voyager_agent.erl` rewrites the
   term, substituting `'$voyager_truncated'` once the budget runs out.
2. **`max_heap_size`** — `with_bounded_heap/1` caps the agent worker at
   `10_000_000` words (~76 MB, `kill => true`), "so a pathological scan is killed
   rather than the node."

## 2. Root cause — truncation runs *after* a full, un‑shared copy

Both `proc_*` paths materialise the **entire** attribute on the remote node
*before* `walk/3` ever runs:

- `proc_messages/3`, `proc_dictionary/3`, `proc_label/2`
  → `erlang:process_info(Pid, messages | dictionary | label)` — copies the whole
  attribute onto the caller's heap in one BIF step.
- `proc_state/3` → `sys:get_state(Pid, Timeout)` — the **observed process itself**
  copies its whole state into the reply message.

`walk/3` (and therefore `budget`, `Limit`, `MAX_BINARY_BYTES`) only shrinks that
already‑built copy on its way to the wire. It bounds the **payload**, exactly as
the docs say — but it does **not** bound the **peak memory or CPU of building the
copy**. Two properties of ERTS turn that gap into a node‑killer:

**(a) Intra‑node term copy flattens sharing.** A message / `process_info` copy is
sized by `erts_debug:flat_size` (sharing lost), not `erts_debug:size` (sharing
kept). A compact term with internal sharing therefore explodes by its sharing
factor when copied:

```
1000 references to one shared 1 MB list:
  on the target heap (shared) :    1.0 MB
  what the copy allocates (flat): 1000.0 MB   → 985× amplification
```

Internal sharing is not exotic — `List.duplicate/2`, a config map handed to many
children, repeated tuple/record references, `:ets` rows fanned into a state, etc.
all produce it. The observed process looks tiny in every Voyager metric
(`process_info(memory)` reports the shared size); the copy is huge.

**(b) `max_heap_size` cannot stop a single oversized copy.** The copy is one
`heap_frag` allocation. `max_heap_size` is a *main‑heap, GC‑time* limit, so it can
only kill the worker *after* the fragment is allocated and merged. If the
fragment fits, the full flat size is allocated transiently (then the worker is
killed — too late to matter for a small node); if it does not fit, the allocator
aborts and the **node crashes** before `max_heap_size` is ever consulted. For
`proc_state` it is worse still: the fragment is allocated by the **observed
business process**, which has no `max_heap_size` at all and is blocked inside its
own `handle_call` while it copies.

## 3. Findings

Every run below used the **default** `budget = 5_000` and `limit = 200`. The
agent function was invoked inside a spawned, monitored worker — exactly how
`:erpc` runs the MFA on the remote node — so `max_heap_size(kill)` lands where it
does in production. `target_heap` is the observed process's real
`process_info(memory)`; `Δpeak_rss` is the node's resident‑memory spike.

### F1 — `proc_state`: unbounded amplification, copy on the unguarded target *(critical)*

| observed state (1.5 MB process) | Δpeak node mem | Δpeak RSS | elapsed | outcome |
|---|---|---|---|---|
| `dup(1 MB, 200×)`  | +1.5 MB\* | **+399 MB**  | 77 ms  | worker killed, node alive |
| `dup(1 MB, 1000×)` | +1428 MB  | **+999 MB**  | 323 ms | worker killed, node alive |
| `dup(1 MB, 3000×)` | +4261 MB  | **+2994 MB** | 998 ms | worker killed, node alive |

\*the erlang‑memory sampler missed the sub‑ms free; RSS (what the OS OOM‑killer
sees) retained it. Peak memory grows **linearly and without bound** in the
sharing factor while the observed process stays at 1.5 MB.

### F2 — same amplification through `proc_dictionary` and `proc_label`

| fetch on a 1.5 MB process | Δpeak RSS |
|---|---|
| `proc_dictionary` (1000 entries sharing one 1 MB value) | **+1000 MB** |
| `proc_label` (label = `dup(1 MB, 1000×)`) | **+999 MB** |

Both copy onto the *guarded* worker via `process_info`, yet RSS still hit ~1 GB
before the `max_heap_size` kill fired — demonstrating F‑root‑cause (b): the cap
does not bound the transient.

### F3 — large *un‑shared* states/mailboxes also amplify (~5–6× transiently)

No contrived sharing needed. A plain 50 MB state spiked RSS by **270 MB** (~5.4×,
from GC copy doubling + the reply fragment + the worker copy); a 50 MB mailbox
spiked **+102 MB**. So a genuinely large but ordinary gen_server state (caches,
buffers, accumulated ETS dumps) of ~1 GB transiently needs ~5–6 GB — enough to
kill a right‑sized host on its own.

### F4 — actual node death on a memory‑constrained node *(the "small machine" round)*

Node booted under `ulimit -v 4600000` (~4.5 GB address space, simulating a small
host). A **single** `proc_state` fetch on the 1.5 MB shared‑state process,
`copies=6000`, default budget:

```
eheap_alloc: Cannot allocate 6291552216 bytes of memory (of type "heap_frag").
Crash dump is being written to: erl_crash.dump...done      # exit 1, whole node gone
```

6 291 552 216 B ≈ `6000 × 1 MB` — the flat size of the copy, in **one**
`heap_frag` allocation. `proc_dictionary` with the same shape crashed identically
(`Cannot allocate 6291696240 bytes … "heap_frag"`). The truncation walk never
ran; the node was gone before it could. On a real 512 MB–2 GB node the *default*
`copies=1000` case from F1/F2 (≈1 GB) is already fatal.

### F5 — full‑node stall on a single‑core node *(the "slow machine" round)*

Node booted with `+S 1` (one scheduler = single core). A heartbeat fired a 5 ms
timer and recorded its worst lateness while one *survivable* `proc_state`
(`copies=1000`, ~1 GB) ran:

```
elapsed_ms=320   heartbeat_worst_stall_ms=314   (heartbeat ticked once instead of ~64×)
```

The expanded‑term copy is non‑yielding: it monopolised the single scheduler and
**froze the entire node for 314 ms**. This scales linearly with the copy size —
seconds‑long freezes precede the crash in F4. Every other process on the node
(request handlers, health checks, `net_ticktime`) is starved for the duration.

### Negative results (tested, *not* exploitable)

- **`external_size` on funs/binaries** — hypothesised CPU amplifier (a fun
  capturing a shared refc binary, re‑measured per fun). 5000 funs sharing one
  4 MB binary walked in **2 ms** with no stall: `external_size` of a binary is
  O(1), so `walk_uncuttable` is not a CPU bomb. No issue.
- **Deep nesting** — a 100 k‑deep list truncates at `budget` in 4 ms; even a
  2 M‑deep list with a 3 M budget is caught by `max_heap_size` (worker killed,
  node alive) with no emulator stack overflow. `budget` bounds `walk/3` recursion
  depth adequately.

## 4. Impact & exploitability

- **Reachability:** triggered by the tool's normal happy path — a user opening a
  process's State / Mailbox / Dictionary / Label. No large `budget`/`limit`
  needed; **the defaults are vulnerable**. The dangerous input lives on the
  *observed* node, so any node Voyager attaches to that happens to run a process
  with a large or internally‑shared term is exposed — including
  crash‑investigation targets, which routinely have huge mailboxes/states.
- **Blast radius:** the observed production node — the one Voyager exists to keep
  alive — not Voyager itself. `proc_state` additionally blocks an innocent
  business process inside its `handle_call`.
- **Severity:** memory‑exhaustion DoS of the monitored node, from a compact
  observed process, at default settings. On constrained nodes it is a reliable
  full‑node crash.

## 5. Recommendations

The budget must bound the **cost of producing** the copy, not only the payload.
Options, roughly in order of effectiveness:

1. **Bound the source before copying.** Prefer size‑capped reads:
   `process_info(Pid, {message_queue_len, _})` / `{messages, N}` where available,
   and for state, gate on `process_info(Pid, memory)` / `heap_size` and **refuse**
   (`{:error, :too_large}`) above a threshold rather than copying first. A refusal
   the UI can render beats a node crash.
2. **Do the copy sharing‑aware and size‑checked.** Use
   `erts_debug:size_shared/1` (or `erlang:external_size/1` with a ceiling) to
   reject / pre‑measure before materialising, so a 985× flat blow‑up is caught
   before allocation, not after.
3. **Run the fetch in a child process with a much smaller `max_heap_size`** and,
   critically, keep the *whole* materialise‑then‑walk step inside it — but note
   F2/F4 show `max_heap_size` alone is insufficient against a single `heap_frag`;
   it must be paired with (1)/(2). For `proc_state`, `max_heap_size` on the agent
   does nothing because the copy is made by the target — a size gate (1) is the
   only real defence there.
4. **Charge budget for binaries by byte in the *copy*, not just the wire**, and
   document that `proc_state` cannot be made safe by truncation alone.

## 6. Reproduction

```
cd process_term_review
erlc voyager_agent.erl

# F1/F2/F3 — amplification (one OS process per run; prints a RESULT line):
elixir bench.exs state_shared mb=1 copies=1000        # ~1 GB from a 1.5 MB process
elixir bench.exs dict_shared  mb=1 copies=1000
elixir bench.exs label_shared mb=1 copies=1000
elixir bench.exs state_flat   mb=50                   # ~5–6× on an un-shared state

# F4 — node crash on a small machine:
bash -c "ulimit -v 4600000; elixir bench.exs state_shared mb=1 copies=6000"

# F5 — full-node stall on a single core:
elixir --erl "+S 1" cpu_latency.exs state_shared_dup mb=1 copies=1000

# mechanism proof (flat vs shared size):
erl -noshell -eval 'X=lists:seq(1,65536),S=lists:duplicate(1000,X),
  io:format("shared=~p flat=~p~n",[erts_debug:size(S),erts_debug:flat_size(S)]),init:stop().'
```

All numbers above are from these scripts on the stated environment.
