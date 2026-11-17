---
paths:
  - "e2e/**"
---

# E2E (Playwright)

`mix e2e` runs `e2e/run.sh`: starts `test@127.0.0.1` (with `mock_app`) and `test6@::1`, then
Playwright against the app under `MIX_ENV=e2e` on :4001.

## Reuse before writing

- Node names, cookies, SSH constants and shared selectors (`sel`) live in `tests/fixtures.ts`;
  import them, never re-declare. Selectors used by one spec go in a local `sel` at its top
- Setup: `ensureConnected(page)` / `ensureDisconnected(page)` in `beforeEach`;
  `waitForLiveView(page)` after every `page.goto`
- Forms: `fillConnectForm`, `switchConnectMode`; they retry until LiveView keeps the value
- Supervision tree: `supervision_tree_helpers.ts` (`openTree`, `clickToggle`, `selectNode`,
  `refreshed`, `rpc`). Drive cytoscape through `_cy` in `page.evaluate`, never canvas clicks
- A helper used by two specs moves to `fixtures.ts` or a `<feature>_helpers.ts`
- Data the node must hold lives in `e2e/mock_app/src/*.erl`; `rpc` only to mutate it mid-test

## Waiting

- **Never** `page.waitForTimeout`. Wait on web-first assertions (`toHaveText`,
  `toHaveAttribute`, `toBeVisible`)
- An action LiveView can drop or re-render goes in `expect(async () => …).toPass()` with
  short inner timeouts
- Assert the end state, not a transition (`loading → ok` races auto-refresh and `phx-throttle`)

## Selectors

- Select by the DOM `id` from the HEEx, or `data-testid` / `data-*` attributes; add an `id` to
  the template rather than selecting by Tailwind class, text or `nth-child`

## Projects

- Every spec runs in both Chromium and Firefox: one project each in `playwright.config.ts`
- Specs share one node and one server. Specs that run before any connection exists
  (`connect_form`, `connect`, `unreadable_secrets`, `recent_connections`) get their own
  projects, chained first; a new spec for a connected node depends on `recent-connections
  firefox`
- A spec that mutates global state (settings, the node's tree) runs serially or after the rest,
  like `supervision-tree` and `processes`
