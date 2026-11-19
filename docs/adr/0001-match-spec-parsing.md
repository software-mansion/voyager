# 1. Match spec parsing and validation

Date: 2026-11-18. Status: accepted.

## Context

Tracing sessions (UI form and the `create_trace_session` MCP tool) and ETS search
(`ets_search_table`) take a match spec typed by a person or written by an LLM. The LLM reads data
from the inspected node, so the input is untrusted. Voyager holds the cookies of the nodes it
inspects, often production ones.

## Decisions

- **Erlang term syntax first.** `Voyager.MatchSpec.parse/1` reads a literal term such as
  `[{['$1', '_'], [{'>', '$1', 10}], []}]` with `:erl_scan` and `:erl_parse.parse_term/1`. Every
  other syntax compiles down to this one, so later syntaxes reuse everything after `parse`.
- **Never evaluate input.** `Code.eval_quoted` or `:erl_eval` would be code execution on Voyager.
  `Macro.quoted_literal?/1` is no safe gate: it refuses negative numbers and accepts structs,
  whose evaluation calls `__struct__/1`. `:erl_parse.parse_term/1` still builds bit-syntax sizes
  (`<<0:99999999999999>>` exhausts memory from 20 bytes), so `parse/1` refuses every `:` token,
  which in Erlang only calls and sized segments use.
- **Composable checks.** `parse/1` only turns the string into a term. `check_shape/1`,
  `check_clauses/2`, `check_actions/2` and `check_compiles/2` are separate, each safe on any
  term, and every input (a form field, an MCP tool, ETS) chains the ones it needs.
- **Errors are reasons.** Checks return atoms or tuples; `format_error/1` makes the message.
- **Compile without running.** `check_compiles/2` prepends a `false` guard before
  `:erlang.match_spec_test/3`, because the body runs there and `{enable_trace, _}` segfaults the
  VM.
- **No atoms created on the inspected node.** `encode/1` replaces every atom but a match variable
  with `{'$voyager_atom', Name}`; the agent resolves it with `binary_to_existing_atom/1` and refuses
  an atom the node lacks with `{unknown_atom, Name}`. Atoms on Voyager are bounded by the 4 KB
  input cap and the atom-headroom refusal; a restart clears them.
- **`return_trace` and `exception_trace` are refused by a check, not stripped.** Return tracing is
  the session's own option today. A caller that leaves the check out lets them through.
- **ETS keeps its behaviour.** `Voyager.Services.Ets.MatchSpec` reuses `parse/1` and
  `check_clauses/2` with a cap of one clause, and still sends plain atoms.

## Findings

- A guarded clause with `{return_trace}` before a `{'_', [], []}` catch-all traces returns only for
  matching calls (OTP 29, `global` and `local`). A call matching no clause produces no event, and
  the first matching clause wins. Per-value return tracing would need the agent to stop refusing
  `return_trace` in a body.
- `'$abc'` and `'$007'` are constants in ERTS; `'$0'`, `'$1'` and so on are variables.

## Later

- Erlang `fun` syntax through `:ms_transform.transform_from_shell/3`.
- Elixir term syntax through `Code.string_to_quoted/2` plus a literal-only walk, never eval.
- Elixir `fn` syntax and a UI builder.
- A `match_spec` field in `Voyager.Services.Tracer.Config`, encoded in `to_agent/2`, with the
  trace clause cap moved into `Refusals.agent_macros/0`.
- Atom encoding for ETS search.
