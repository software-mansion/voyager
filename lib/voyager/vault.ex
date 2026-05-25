defmodule Voyager.Vault do
  @moduledoc """
  Cloak vault used to encrypt sensitive fields at rest (currently: remote node cookies).

  The active cipher is configured at runtime in `config/runtime.exs`. The key is
  loaded from the `VOYAGER_VAULT_KEY` env var (base64) or, if unset, from a local
  file at `~/.voyager/vault.key`, which is generated on first boot.
  """
  use Cloak.Vault, otp_app: :voyager
end
