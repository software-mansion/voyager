# Voyager

Phoenix 1.8 / LiveView app, with a Tauri desktop shell in `rel/app`, that connects to remote BEAM
nodes and inspects them. Area-specific rules live in `.claude/rules/` and load when you work on
matching files.

## Commands

- `mix precommit` when you are done; fix everything it reports (warnings, format,
  `credo --strict`, tests)
- `mix test test/path/to_test.exs`, `mix test --failed`
- `mix e2e` runs the Playwright suite (`mix e2e.setup` once first)
- `mix tauri.test` for the Rust shell

## Architecture

- Persistent Ecto schemas: `lib/voyager/schemas/` as `Voyager.Schemas.Resource`, never nested
  under a feature module
- LiveView form param schemas (embedded): `lib/voyager_web/form_schemas/` as
  `VoyagerWeb.FormSchemas.ResourceParams`, never in `lib/voyager/`
- No context modules. Per resource, `Voyager.Queries.Resource` holds reads (list-all is `all/0`)
  and `Voyager.Actions.Resource` holds writes. Actions may call queries; LiveViews alias both as
  `ResourceQueries` / `ResourceActions`
- Services: `lib/voyager/services/` as `Voyager.Services.Name`, for non-CRUD work (remote nodes,
  external systems, side effects). GenServers and LiveViews call them directly
- `lib/voyager` never depends on `lib/voyager_web`; pass plain arguments, not web structs
- A service owns its feature end to end: setting keys, valid values, load, save, lock
- Pure logic stays out of lifecycle GenServers, in a plain module the GenServer calls
- Remote node calls go through `Voyager.Erpc`, mocked as `Voyager.ErpcMock` in tests

## Code rules

- Before writing a helper, look for one in this repo, then stdlib/OTP, then an installed dep.
  A shared constant lives in one module attribute behind a function, not copied across files
- Delete what has no caller: unused attrs and args, unreachable clauses, one-use wrappers.
  A function used only inside its module is `defp`, never public just for a test
- One name per concept across schema, field, event and assign
- `@spec` on public functions, with real types (structs, `String.t()`) where they exist
- One module per file; no new dependencies unless asked; HTTP through `Req`
- `String.to_atom/1` only on cookies, node names and the settings-driven distribution suffix,
  never on other user input
- **Never** `String.to_existing_atom/1` on params, stored settings or other stale input: it raises
  when the atom is not loaded in a fresh VM. Match against a known list first
- No raising calls (`System.cmd/3`, `Map.fetch!/2`, `hd/1`, `String.trim/1` on `nil`) on a path
  reachable from params or from a supervised process
- ETS tables are `:protected` unless another process has to write to them
- **Never** put secrets in logs or `inspect` output (structs holding `api_key`, cookies,
  passwords)
- Check the result of writes (`Voyager.Settings.put/2`, `Repo` calls,
  `:telemetry.attach_many/4`)
- New events, routes and branches get a test
- New modules in `lib/` get `@moduledoc false` (Credo's `ModuleDoc` check requires the
  attribute); no `@moduledoc` / `@doc` text unless asked. Test modules get no `@moduledoc`

## Comments

Comment only a non-obvious why (a workaround, an OTP/Phoenix/remote-node constraint), in one line
that names the API or failure mode. Never restate the code. Full rules:
`.claude/rules/comments.md`.

## Skills

- `pr-review`: review a PR against this repo's rules; CI runs it on `@claude review`
- `changelog`: write the next `CHANGELOG.md` section from merged PRs
- `ponytail-review`: over-engineering pass over a diff; `pr-review` runs it after the defect
  review
