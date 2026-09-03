# ProcessTerm memory/DoS red-team harness

Reproduces the findings in `REPORT.md` against the term-bounding logic added in
PR #213 ("Add ProcessTerm API", software-mansion/voyager).

`voyager_agent.erl` here is a verbatim copy of `priv/voyager_agent.erl` at the
PR head (commit `ef80729`), vendored so the harness is self-contained.

## Run

    erlc voyager_agent.erl            # produces voyager_agent.beam

    # memory amplification / node death (each run is one OS process):
    elixir bench.exs state_shared mb=1 copies=1000 budget=5000
    elixir bench.exs state_flat   mb=50
    elixir bench.exs dict_shared  mb=1 copies=1000
    elixir bench.exs label_shared mb=1 copies=1000
    elixir bench.exs msg_heap     mb=50 count=1000

    # actual node crash under a memory-limited ("small machine") node:
    bash -c "ulimit -v 4600000; elixir bench.exs state_shared mb=1 copies=6000"

    # scheduler stall on a single-core ("slow machine") node:
    elixir --erl "+S 1" cpu_latency.exs state_shared_dup mb=1 copies=1000

Each `bench.exs` run prints one `RESULT` line: peak node memory / RSS, the
observed process's real heap size, elapsed time, and the outcome.
