---
paths:
  - "lib/voyager_web/live/**"
  - "lib/voyager_web/components/**"
  - "lib/voyager_web/hooks/**"
  - "lib/voyager_web/form_schemas/**"
---

# LiveView

## Structure

- The app shell (navbar, sidebar, statusbar) and flash come from the `live_session` layout; a
  LiveView renders only its own content
- `Live` suffix only on LiveViews, never on LiveComponents
- Avoid LiveComponents unless there is a specific need; prefer a function component
- Function components take the event name and target as attrs, never hardcode `phx-click` /
  `phx-target`: `<.chip on_select="select-link" target={@myself} node_key={key} />`
- A LiveComponent initializes its own assigns (form, lock flags, counters) in `mount/1`, not with
  `assign_new/3` in `update/2`. `update/2` assigns only what the parent passes; re-assigning a
  form from persisted state there wipes in-progress edits on every parent render
- `assign_new/3` never refreshes: don't use it for a value derived from runtime config
- Components in `core_components.ex` take `id={@id}`, no hardcoded DOM ids
- `attr`: no `required: true` for a value that can be `nil`, no `:any` where a struct or
  `:string` fits
- Compute derived values into assigns, not inside HEEx; assign static values once in `mount`
- No `raw/1`
- `push_navigate` only within one `live_session`; across sessions use `href`
- Subscribe to a PubSub topic once per process: in the `on_mount` hook or in `mount/3`, not both

## Socket returns

`noreply/1` and `ok/1` (`VoyagerWeb.Helpers`) only at the end of a pipe; otherwise the tuple:

    socket
    |> assign(:status, :ok)
    |> noreply()

    {:noreply, socket}

Never `noreply(socket)` unpiped, `do: noreply(socket)`, or `{:noreply, socket |> f()}`.

## Untrusted params

Params from events, URLs and hooks can be tampered with.

- **Never** `String.to_integer/1` on a param: a bad value raises and kills the LiveView. Use
  `Integer.parse/1` or pattern matching and ignore invalid values
- Validate intervals, page sizes and options against the allowed set; `"-5"` reaching
  `Process.send_after/3` raises
- **Never** interpolate a user-supplied segment into a path; use `~p` (node names contain `/`
  and `@`)
- **Never** accept a `return_to` because it starts with `"/"`: `//evil.example` leaves the app

## Async state

- Every `handle_async` failure branch sets the error state; never leave an `AsyncResult`
  `:loading` or `:ok`
- The reason a `handle_async` failure passes on has a clause in that view's `format_error/1`;
  otherwise the user gets the catch-all message
- One result per independently loaded section; don't fold several remote calls into one
  `:ok` / `:error` assign
- `assign_async(..., reset: false)` keeps `ok?: true` on a failed refresh; surface the failure
- Handle `{:exit, {:shutdown, :cancel}}` from a cancelled task
- `get_field/2` returns values from a changeset that failed validation; check `valid?` first

## Streams

Use streams for large or growing collections (process lists, ETS rows, trace entries); plain
assigns are fine for small, bounded lists.

- The parent has `phx-update="stream"` and a DOM id; each child uses the stream id:
  `<div :for={{id, row} <- @streams.rows} id={id}>`
- Streams are not enumerable: to filter or refresh, refetch and
  `stream(socket, :rows, rows, reset: true)`
- Track counts in a separate assign; the empty state is a sibling
  `<div class="hidden only:block">`, the only element next to the `:for`
- To change content inside streamed items, `stream_insert/3` them again with the assign change
- Never `phx-update="append"` / `"prepend"`

## Forms

- Build forms from a changeset of a `VoyagerWeb.FormSchemas.*Params` embedded schema:
  `ConnectionParams.changeset(params) |> to_form(as: :conn)`
- Template: `<.form for={@form} id="conn-form">` with `<.input field={@form[:field]}>`
- Never pass a changeset to the template, never `<.form let={f}>`
