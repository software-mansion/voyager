defmodule Voyager.VaultKey do
  @moduledoc """
  Loads or generates the local 32-byte AES key used by `Voyager.Vault`.

  Resolution order:
    1. `VOYAGER_VAULT_KEY` env var (base64-encoded 32 bytes)
    2. File at `~/.voyager/vault.key`, generated on first boot with mode 0600

  Losing the key file makes any previously stored encrypted values unrecoverable.
  """

  @key_bytes 32

  def resolve! do
    case System.get_env("VOYAGER_VAULT_KEY") do
      nil -> load_or_generate!()
      encoded -> decode_env_key!(encoded)
    end
  end

  defp decode_env_key!(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == @key_bytes ->
        key

      _ ->
        raise """
        VOYAGER_VAULT_KEY must be a base64-encoded #{@key_bytes}-byte key.
        Generate one with:
            mix run -e "IO.puts Base.encode64(:crypto.strong_rand_bytes(32))"
        """
    end
  end

  defp load_or_generate! do
    path = key_path()

    case File.read(path) do
      {:ok, key} when byte_size(key) == @key_bytes -> key
      _ -> generate_and_store!(path)
    end
  end

  defp generate_and_store!(path) do
    key = :crypto.strong_rand_bytes(@key_bytes)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, key)
    File.chmod!(path, 0o600)
    key
  end

  defp key_path do
    Path.join([System.user_home!(), ".voyager", "vault.key"])
  end
end
