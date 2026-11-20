---
paths:
  - "lib/voyager/services/**"
---

# Services

- **Cached derived state**: a value a GenServer derives from the database or a setting and keeps
  in its state (a Tracer session's `storage_limit`) is recomputed by every write to its inputs,
  including writes to other rows (deleting another saved session). Each such write calls one
  refresh function; a write that skips it is a finding
