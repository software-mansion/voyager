---
paths:
  - "lib/voyager_web/**"
  - "assets/css/**"
---

# HEEx and UI

## Components

- Icons are SVGs in `assets/css/icons/`, rendered with `<.icon name="icon-{file}" class="size-4">`.
  An icon is a CSS mask on `currentColor`: color it with `text-*`, never `bg-*`. The name must
  match an existing SVG, or it renders as an empty span
- Form inputs use `<.input>` from `core_components.ex`. A custom `class` replaces the default
  classes, so it must style the input fully
- `<.flash_group>` is called only from `layouts.ex`
- Key elements (forms, buttons, panels) get unique DOM ids; tests select on them

## Styling

- DaisyUI components (`btn`, `menu`, `badge`, `card`, `modal`, ...) first, Tailwind utilities for
  layout and spacing
- Colors only from DaisyUI semantic tokens (`bg-base-100`, `text-base-content`, `text-error`,
  ...); themes are `voyager-light` (default) and `voyager-dark`
- Reuse project classes (`toolbar-icon-sm`, `sidebar-label`) and DaisyUI modifiers
  (`btn-square`) before adding new ones
- Tailwind's built-in scale, not arbitrary values (`w-[13px]`, `flex-[2]`); sizes in custom CSS
  use `rem`, not `px`
- Don't override a component's colors in a way that breaks its hover state
- `app.css` keeps the Tailwind v4 import block (`@import "tailwindcss" source(none);` plus the
  `@source` lines); never `@apply`
- Only the `app.js` and `app.css` bundles exist: import vendor code there, never link external
  scripts or stylesheets from layouts

## HEEx syntax

- `{...}` for interpolation in attributes and tag bodies; `<%= ... %>` only for block constructs
  (`if`, `case`, `cond`, `for`) in tag bodies
- `:if` / `:for` attributes over `<%= if %>` / `<%= for %>` blocks
- Class lists use `[...]`:
  `class={["px-2", @active && "font-bold", if(@muted, do: "opacity-60", else: "opacity-100")]}`
- Literal `{` / `}` inside `<pre>` / `<code>` need `phx-no-curly-interpolation` on the parent

## Accessibility

- Icon-only buttons have `type="button"` and a `title` or `aria-label`; without `type` they
  submit the enclosing form
- Every `<label>` has `for`; a nav item keeps an accessible label when compact mode hides its text
- Tooltip triggers are focusable; nothing leaves the tab order (`tabindex="-1"`) without a
  keyboard handler
