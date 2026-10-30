defmodule Voyager.Encrypted.Binary do
  @moduledoc false
  use Ecto.Type

  @header <<1, 10, "AES.GCM.V1">>
  @aad "AES256GCM"

  def type, do: :binary

  def cast(value) when is_binary(value) or is_nil(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    {:ok, @header <> iv <> tag <> ciphertext}
  end

  def dump(_), do: :error

  def load(nil), do: {:ok, nil}

  def load(<<@header::binary, iv::binary-16, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  def load(_), do: :error

  defp key, do: Application.fetch_env!(:voyager, :vault_key)
end
