# 1. Match spec parsing and validation

Date: 2026-11-18. Status: accepted.

Tracing sessions and ETS search take a match spec typed by a person or written by an LLM that
reads data from the inspected node, so the input is untrusted. Voyager holds the cookies of the
nodes it inspects, often production ones.

## Decisions

- **Never evaluate input.** A spec is read with `:erl_scan` and `:erl_parse`, never
  `Code.eval_quoted` or `:erl_eval`: that would be code execution on Voyager.
  `Macro.quoted_literal?/1` is no safe gate either, since it accepts structs, whose evaluation
  calls `__struct__/1`.
- **Functions go through OTP's own `fun2ms` transform.** `:ms_transform.transform_from_shell/3`
  translates the fun instead of a translator of ours. It folds constant operators while doing
  so, which is why `!` is refused (`init ! {stop, stop}` would really send) and why parsing is
  bounded.
- **Elixir compiles to the Erlang form through `:elixir.quoted_to_erl/2`**, then takes the
  Erlang path. The alternative, a hand-written translator of the quoted `fn`, was 400 lines to
  keep in step with `ms_transform`. The costs: `quoted_to_erl/2` is private to Elixir, and
  expansion runs macros, so the env imports only six Kernel macros and `import`, `require`,
  `%Name{}` and remote calls outside `:erlang` are refused before expanding.
- **Parsing is bounded by a process, not by refusing syntax.** It runs under `max_heap_size`
  (8 MiB) with a 2 s timeout, so operators and bit syntax stay usable. One binary segment is a
  single allocation the heap limit cannot interrupt, so segment sizes are capped before
  anything is built.
- **No atoms are created on the inspected node.** A plain atom in a dist message is created
  when the message is decoded, and a full atom table aborts the VM. Every atom but a match
  variable is sent as `{'$voyager_atom', Name}`, which the agent resolves with
  `binary_to_existing_atom/1` and refuses if the node lacks it: no row or call can hold an atom
  the node does not have. Voyager's own atom table is protected only by the 4 KiB input cap and
  a headroom check; a restart clears it.
- **Checks are separate functions that take their limits as arguments.** A spec is not tied to
  one use: tracing allows ten clauses and ETS select one, so each caller chains the checks it
  needs and passes the agent's values from `Refusals`.
- **`return_trace` and `exception_trace` are refused by a check, not stripped.** Return tracing
  is the session's own option today. A caller that leaves the check out lets them through.
