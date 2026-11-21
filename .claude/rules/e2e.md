---
paths:
  - "e2e/**"
---

# E2E (ExUnit with playwright_ex)

`mix e2e` (`mix e2e.setup` once first) runs `mix test` under `MIX_ENV=e2e`, with the suite in
`e2e/`. `e2e/test_helper.exs` starts `test@127.0.0.1` (with `mock_app`) and `test6@::1` through
`e2e/node.sh` and the app on :4001. `--seed 0` runs a module's tests in definition order; the order of modules is not defined, so each module
sets up its own connection state (`ensure_connected` / `ensure_disconnected`).

## Reuse before writing

- Node names, cookies, SSH constants and shared selectors (`sel/1`) live in
  `e2e/support/fixtures.ex`; use them, never re-declare. Selectors used by one test module go in
  module attributes at its top
- Setup: `ensure_connected(page)` / `ensure_disconnected(page)` in `setup`;
  `wait_for_live_view(page)` after every `Page.goto!`
- Forms: `fill_connect_form`, `switch_connect_mode`; they retry until LiveView keeps the value
- Supervision tree: `e2e/support/tree_helpers.ex` (`open_tree`, `click_toggle`, `select_node`,
  `refreshed`, `rpc`). Drive cytoscape through `cy_node` and `Page.evaluate!`, never canvas
  clicks
- A helper used by two test modules moves to `fixtures.ex` or a `<feature>_helpers.ex`
- Data the node must hold lives in `e2e/mock_app/src/*.erl`; `rpc` only to mutate it mid-test

## Waiting

- **Never** `Process.sleep` in a test. Wait on web-first assertions (`Expect.to_have_text!`,
  `Expect.to_have_attribute!`, `Expect.to_be_visible!`)
- An action LiveView can drop or re-render goes in `Expect.to_pass!/2` with short inner timeouts
- Assert the end state, not a transition (`loading → ok` races auto-refresh and `phx-throttle`)

## Selectors

- Select by the DOM `id` from the HEEx, or `data-testid` / `data-*` attributes; add an `id` to
  the template rather than selecting by Tailwind class, text or `nth-child`

## Browsers and ordering

- Every module runs in both Chromium and Firefox via `use Voyager.E2E.Case, project: "<name>"`, as
  the projects `<name> chromium` and `<name> firefox` (`devices:` narrows it)
- Specs share one node and one server. ExUnit runs async modules first, then the sync ones one by one
  (see `e2e/support/case.ex`). A module that disconnects or reconnects the session
  (`connect_form`, `ssh_config`, `connect`, `unreadable_secrets`, `recent_connections`) is
  `async: false`; a module for a connected node is `async: true`
- A module that mutates global state (settings, the node's tree) uses `group:` so its browsers
  run one after the other (`supervision_tree`), or is sync (`processes`)
