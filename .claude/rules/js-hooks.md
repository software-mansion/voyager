---
paths:
  - "assets/js/**"
  - "lib/voyager_web/**"
---

# LiveView JS hooks

- A hook that manages its own DOM (tooltips included) sets `phx-update="ignore"`, or re-renders
  wipe its open/pinned state; a `phx-hook` element always has a unique id
- Inline JS is a colocated hook, `<script :type={Phoenix.LiveView.ColocatedHook} name=".Name">`,
  never a raw `<script>`; its name starts with `.`
- External hooks live in `assets/js/hooks/` and are registered in the `LiveSocket` `hooks` option
  in `assets/js/app.js`
- Server to client: `push_event/3`, then return or rebind the socket it returns; the hook listens
  with `this.handleEvent`. Client to server with a reply: `this.pushEvent(name, payload, cb)`,
  answered by `{:reply, map, socket}`

## Lifecycle

- Every `setTimeout` / `setInterval` gets a named field and is cleared in `destroyed()`; remove
  `scroll` / `resize` listeners and `unlisten` Tauri listeners (`onThemeChanged`) there too
- Build per-instance state (`new Map()`, caches) in `mounted()`, never on the hook object, or it
  leaks between instances
- One hook per widget, not per table cell: use `title`, or one delegated hook for the table

## Data from the server

- **Never** build `innerHTML` from server-provided process metadata without escaping; prefer
  `textContent`
- Payload shapes: Erlang tuples arrive as arrays, `registered_name` is `[]` when unregistered,
  `pid` is `null` for ghost nodes
- Don't reimplement formatting that exists in Elixir (PIDs, terms); send the formatted value
- No leftover `console.log`
