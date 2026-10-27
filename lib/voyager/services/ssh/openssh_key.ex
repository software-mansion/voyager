defmodule Voyager.Services.SSH.OpensshKey do
  @moduledoc false

  alias Voyager.Services.SSH.BcryptPbkdf

  @begin "-----BEGIN OPENSSH PRIVATE KEY-----"
  @end_marker "-----END OPENSSH PRIVATE KEY-----"

  defguard is_openssh_pem(pem)
           when is_binary(pem) and byte_size(pem) >= byte_size(@begin) and
                  binary_part(pem, 0, byte_size(@begin)) == @begin

  @type reason ::
          :key_passphrase_required
          | :key_bad_passphrase
          | :key_unsupported_cipher
          | :key_unreadable

  @spec decrypt(binary(), String.t() | nil) ::
          {:ok, :public_key.private_key()} | {:error, reason()}
  def decrypt(pem, passphrase) do
    with {:ok, container} <- parse(pem),
         :ok <- check_cipher(container.cipher),
         :ok <- require_passphrase(passphrase),
         {:ok, plain} <- decrypt_private(container, passphrase) do
      decode(container, plain)
    end
  end

  defp require_passphrase(nil), do: {:error, :key_passphrase_required}
  defp require_passphrase(_passphrase), do: :ok

  defp parse(pem) do
    with [_, body | _] <- String.split(pem, [@begin, @end_marker]),
         {:ok, <<"openssh-key-v1", 0, rest::binary>>} <- Base.decode64(body, ignore: :whitespace),
         {:ok, [cipher, "bcrypt", kdf_options], <<nkeys::32, rest::binary>>} <- strings(rest, 3),
         {:ok, public_keys, rest} <- strings(rest, nkeys),
         {:ok, [encrypted], _rest} <- strings(rest, 1),
         {:ok, [salt], <<rounds::32>>} <- strings(kdf_options, 1) do
      {:ok,
       %{
         cipher: cipher,
         salt: salt,
         rounds: rounds,
         public_keys: public_keys,
         encrypted: encrypted
       }}
    else
      _ -> {:error, :key_unreadable}
    end
  end

  defp decrypt_private(container, passphrase) do
    <<key::binary-32, iv::binary-16>> =
      BcryptPbkdf.derive(passphrase, container.salt, container.rounds, 48)

    case :crypto.crypto_one_time(:aes_256_ctr, key, iv, container.encrypted, false) do
      <<check::32, check::32, _::binary>> = plain -> {:ok, plain}
      _ -> {:error, :key_bad_passphrase}
    end
  end

  defp decode(container, plain) do
    body =
      [
        "openssh-key-v1\0",
        string("none"),
        string("none"),
        string(""),
        <<length(container.public_keys)::32>>
      ]
      |> Enum.concat(Enum.map(container.public_keys, &string/1))
      |> Enum.concat([string(plain)])
      |> IO.iodata_to_binary()

    case :ssh_file.decode(
           Enum.join([@begin, Base.encode64(body), @end_marker], "\n"),
           :openssh_key_v1
         ) do
      [{key, _attrs} | _] -> {:ok, key}
      _ -> {:error, :key_unreadable}
    end
  end

  defp strings(bin, 0), do: {:ok, [], bin}

  defp strings(<<len::32, value::binary-size(len), rest::binary>>, n) do
    with {:ok, values, rest} <- strings(rest, n - 1), do: {:ok, [value | values], rest}
  end

  defp strings(_bin, _n), do: :error

  defp string(value), do: <<byte_size(value)::32, value::binary>>

  defp check_cipher("aes256-ctr"), do: :ok
  defp check_cipher(_cipher), do: {:error, :key_unsupported_cipher}
end
