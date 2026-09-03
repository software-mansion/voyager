# ProcessTerm — production realism, heavy-load impact, RateLimiter tuning & fix

Follow-up to `REPORT.md`. Answers three questions: are the findings realistic on
big production nodes; how bad is this at the worst moment (a node already under
load); and can the existing `RateLimiter` be tuned to make it safe. Same
environment (OTP 29, 4 vCPU, 16 GB); all numbers from the harness here.

## 1. Realistic on huge production nodes?

**Yes — node size only moves the threshold, it does not remove the failure.**
The copy the fetch builds is unbounded, so "how big a node" only decides how big
an observed process has to be to kill it. Three reasons it is reachable in real
systems, not just a lab:

- **Runaway mailboxes are the #1 BEAM overload symptom, and are exactly what you
  inspect.** `proc_messages` copies the whole mailbox (the code says so). A 1 M
  message mailbox already copies in **466 ms / ~107 MB** *for trivial messages*;
  a real stuck consumer holds millions of fat messages = multi‑GB. The bigger the
  incident, the bigger the copy.
- **Sharing amplification is data‑dependent and unbounded** (985× measured;
  666× for the state case). A process holding e.g. 100 k references to one shared
  1 MB config (~2 MB resident) copies as **~100 GB** — fatal on a 64–256 GB node
  from a process that looks 2 MB in every metric. Shared config/schema/template
  references, `List.duplicate`, ETS rows fanned into a state all produce this.
- **It is already on a hot path.** `fetch_label` is called **directly, un‑rate‑
  limited, on every process‑details open** (`details_panel.ex:167`); a label is
  an arbitrary `:proc_lib.set_label/1` term. `fetch_state`/`fetch_messages` are
  the new explicit reads.

What a big node *does* buy: a single 1–6 GB copy is survivable at rest (worker is
`max_heap_size`‑killed, node lives). So on a well‑provisioned, **idle** node the
common case degrades rather than crashes. The crash needs either a genuinely huge
target or a high sharing factor — or a node that is not idle, which is §2.

## 2. Impact under heavy load (the critical moment) — this is the real problem

Voyager's job is to help when a node is in trouble. That is precisely when these
reads are most dangerous, because the failure modes compound:

- **No headroom.** Under load, free memory is already low. A transient copy that
  is "harmless" at rest now crosses the line and trips the **OS OOM‑killer**,
  which can take the whole `beam` (or a sibling container) — `max_heap_size`
  killing the ephemeral worker afterwards is too late; the allocation already
  happened.
- **You block the hot process.** `sys:get_state` runs *inside the target*. On a
  busy `gen_server` the system message queues **behind its already‑long mailbox**
  → the 5 s timeout fires → Voyager shows **nothing, exactly when you need it**,
  and it tied up a worker for 5 s. If it *does* run, the hot process stops serving
  to copy its state, so its backlog grows — **positive feedback into the
  overload**.
- **Non‑yielding stall on few cores.** Production pods are often 1–2 cores. The
  copy does not yield: measured **314 ms full‑node freeze** for one 1 GB `proc_state`
  on a single scheduler (`net_ticktime`, health checks, request handlers all
  starved for the duration; scales linearly toward the crash).

Net: the tool meant to diagnose the incident can deepen it — a classic
observer‑effect. Making these reads *safe under load* is the actual requirement.

## 3. Can the RateLimiter fix it? — study & tuning

`Voyager.Services.RateLimiter` is a **global token bucket** (`:high` cap 10 /
refill 5·s⁻¹; `:low` cap 2 / refill 1). Two structural facts decide everything:

1. **A token = one request, regardless of cost.** A 4 KB label fetch and a 6 GB
   state fetch each cost 1 token.
2. **`run/3` executes the work in the caller.** The bucket gates *admission rate*,
   not *concurrency* and not *cost*. `capacity` is a **burst of simultaneous
   admissions** — i.e. how many expensive copies can run at once.
3. **It is not wired in.** `RateLimiter.run/3` has **no caller in `lib`** (main or
   PR head) — only its own doc example. Every fetch above currently bypasses it.

### Measured (fetches driven through the real RateLimiter, 16 clients, 3 s)

Capacity is the burst of concurrent copies, so peak load tracks `capacity ×
per‑request cost`:

| cap / refill | admitted | throughput | Δpeak RSS (64 MB/copy) | worst stall |
|---|---|---|---|---|
| 10 / 5 (default) | 20 | 6.7 /s | **+620 MB** | **968 ms** |
| 4 / 2 | 10 | 3.3 /s | ~0 | 18 ms |
| 2 / 1 | 5 | 1.7 /s | ~0 | 20 ms |
| 1 / 1 | 4 | 1.3 /s | ~0 | 4 ms |

- **`capacity` controls peak; `refill` controls sustained throughput.** The
  default cap 10 lets a burst of ten copies overlap → +620 MB and a ~1 s freeze;
  cap ≤ 4 absorbs a 64 MB‑per‑copy workload comfortably.
- **Cost sweep (cap 4 fixed):** peak scaled straight with per‑request size
  (50 MB→~1 GB, 100 MB→~1.9 GB peak). A "safe" rate still DoSes if one request is
  fat.
- **Decisive:** at the *tightest* setting (cap 1 / refill 1) the limiter still
  **admits** the request; a single admitted `proc_state` is unbounded (F1: ~1 GB;
  F4: whole‑node crash). **Rate limiting cannot prevent a single‑request DoS.**

### Best RateLimiter settings — necessary, not sufficient

Since `capacity × cost` is the exposure and `cost` is unbounded, no bucket setting
is safe on its own. Tune it as a *concurrency* backstop and pair it with a
per‑request cap (§4):

- **Wire it up first** — route `ProcessTerm.fetch_*` and
  `ProcessInfo.fetch_dictionary/label` through it (today they bypass it).
- **Give the unbounded term reads their own tiny bucket**, separate from cheap
  fixed‑size `ProcessInfo.fetch`: `capacity: 1–2`, `refill: 1`,
  `refill_interval_ms: 1_000`. At most 1–2 concurrent heavy copies. Leave cheap
  fixed‑size reads on the existing `:high` bucket (cap 10) — they are bounded, a
  burst is fine.
- **Prefer a concurrency semaphore over a rate.** Because `run/3` runs in the
  caller, what you actually want to bound is *in‑flight* heavy reads (a max‑2
  semaphore), not requests‑per‑second. Rate limits a 1 s window; a burst inside it
  still overlaps.
- With a per‑request payload cap `C` (§4) and burst `B`, worst‑case transient ≈
  `B × C × 2` (GC). Target that under your smallest pod's headroom — e.g.
  `B=2, C=8 MB → ~32 MB`, safe anywhere.

## 4. The actual fix — bound the work, not just the payload (layered)

The budget bounds the wire payload; it must also bound *building the copy*.

- **L0 — O(1) pre‑flight gate (do this first, it is cheap and it is the fix for
  the worst case).** Before any term read, check fixed‑size counters —
  `process_info(Pid, [:message_queue_len, :total_heap_size, :heap_size])`, all
  O(1) (`message_queue_len` = **12 µs on a 1 M‑msg mailbox**). Refuse above a
  threshold and **return the size**. For an incident, "PID X holds 4.2 M messages
  / 800 MB heap" *is the answer* — you do not need the contents. This fully closes
  the **runaway‑mailbox** case (exact count, no copy) and the large‑flat‑state /
  dictionary case.
- **L1 — residual sharing expansion.** The `:memory` gate reports the *shared*
  size, so it misses a compact‑but‑shared term by up to **666×**. OTP has no
  sharing‑preserving bounded copy, so cap the copy with a **small absolute
  `max_heap_size` child** (near the byte budget, not 76 MB) *and* the §3
  concurrency limit; accept that a single monster `heap_frag` is the rare residual
  (state/dict have far lower sharing likelihood than mailboxes have size).
- **L2 — short `sys:get_state` timeout**, and treat timeout as "process busy"
  (itself diagnostic) instead of blocking a worker for 5 s.
- **L3 — the RateLimiter of §3**, wired, with a small dedicated bucket /
  semaphore for these reads.
- **L4 — lead with the cheap fixed‑size metrics** (Voyager already fetches these
  safely on refresh) and gate the expensive contents behind an explicit,
  size‑aware click.

**Bottom line:** rate limiting is worth wiring and tuning (cap ≤ 2 for the heavy
reads, separate bucket, ideally a concurrency semaphore), but it is a backstop.
The load‑bearing fix is the L0 size gate: it is O(1), it makes the #1 overload
symptom (a runaway mailbox) safe to inspect, and it turns "copy it and hope" into
"measure it, show the size, fetch contents only when known‑bounded" — which is
what lets Voyager stay safe on a node that is already under heavy load.

## Reproduction

```
cd process_term_review && erlc voyager_agent.erl
# RateLimiter capacity/refill/cost sweep:
elixir ratelimit_bench.exs cap=10 refill=5 clients=16 share=64
elixir ratelimit_bench.exs cap=2  refill=1 clients=16 share=64
elixir ratelimit_bench.exs cap=4  refill=2 clients=16 cost=100   # flat-cost sweep
elixir ratelimit_bench.exs cap=1  refill=1 clients=1  share=1500 # one request, unbounded
# gate / capped-read facts:
elixir assess.exs
```
