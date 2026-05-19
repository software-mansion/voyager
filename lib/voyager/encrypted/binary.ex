defmodule Voyager.Encrypted.Binary do
  @moduledoc "Ecto type that transparently encrypts/decrypts a binary via `Voyager.Vault`."
  use Cloak.Ecto.Binary, vault: Voyager.Vault
end
