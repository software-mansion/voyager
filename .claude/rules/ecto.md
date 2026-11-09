---
paths:
  - "lib/voyager/schemas/**"
  - "lib/voyager/queries/**"
  - "lib/voyager/actions/**"
  - "priv/repo/**"
---

# Ecto

- Schemas define `@type t`; text columns are `field :name, :string`
- Read changeset values with `Ecto.Changeset.get_field/2`, never `changeset[:field]`
- Fields the code sets (ids, ownership, computed values) are put on the struct, never in `cast`
- `validate_number/2` has no `:allow_nil` option; validations already skip `nil`
- Preload the associations a template reads
- Generate migrations with `mix ecto.gen.migration name_with_underscores`
- SQLite holds its write lock for the whole `Repo.transact/2`: do encoding and other heavy work,
  including materializing lazy streams, before the transaction and keep only the writes inside
- Delete stored secrets once they are no longer needed (e.g. when the auth method changes)
