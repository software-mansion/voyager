---
paths:
  - "test/**"
---

# Tests

## Processes and isolation

- Start processes with `start_supervised!/1`
- No `Process.sleep/1` or `Process.alive?/1`. Wait for an exit with `Process.monitor/1` and
  `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`; synchronize with
  `_ = :sys.get_state(pid)`
- **Never** `async: true` in a module that calls `Application.put_env/3` or stops `:net_kernel`:
  app env and distribution are VM-global
- Restore env in `on_exit` to the captured previous value, not a hardcoded default
- Isolate every global file and env the code reads (redirect `:global_known_hosts_path`, not only
  `HOME`)
- Clean up spawned processes, ports and temp dirs

## Assertions

- Assert the exact value that proves the behaviour (the field, status or error), so the defect
  cannot pass; check state before and after a transition
- Don't assert on `hd(changeset.errors)` or query-param order; neither is ordered
- Pull pure logic into a module and unit-test it directly instead of only through a LiveView

## LiveView tests

- `Phoenix.LiveViewTest` with `element/2` / `has_element?/2` on DOM ids from the template; never
  assert on raw HTML or copy text
- Drive forms with `render_change/2` / `render_submit/2`; wait for async work with
  `render_async/1`
- To debug a selector, print only the match:
  `render(view) |> LazyHTML.from_fragment() |> LazyHTML.filter("sel") |> IO.inspect()`

## Helpers

Use what `test/support/` has before writing a helper, and put new shared helpers there:

- `Voyager.ErpcMock` (Mox, `test/test_helper.exs`) for remote calls
- `ssh_server.ex`, `ssh_keys.ex` for SSH
- `remote_fixture.ex`, `fixture_app.ex` for a real peer node; start one only when the test needs
  real distribution
- `mcp_case.ex` for MCP tools; `fakes.ex`, `ets_fakes.ex`
