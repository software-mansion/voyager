defmodule Voyager.Services.SSH.KeyFile do
  @moduledoc false

  alias Voyager.Services.LocalFiles

  @type reason ::
          :key_encrypted_openssh
          | :key_passphrase_required
          | :key_bad_passphrase
          | :key_unreadable
          | {:read_failed, {Path.t(), File.posix()}}

  @openssh_begin "-----BEGIN OPENSSH PRIVATE KEY-----"
  @openssh_end "-----END OPENSSH PRIVATE KEY-----"

  @rsa_algorithms [:"rsa-sha2-256", :"rsa-sha2-512", :"ssh-rsa"]

  @curve_algorithms %{
    {1, 3, 101, 112} => [:"ssh-ed25519"],
    {1, 3, 101, 113} => [:"ssh-ed448"],
    {1, 2, 840, 10_045, 3, 1, 7} => [:"ecdsa-sha2-nistp256"],
    {1, 3, 132, 0, 34} => [:"ecdsa-sha2-nistp384"],
    {1, 3, 132, 0, 35} => [:"ecdsa-sha2-nistp521"]
  }

  @spec check(Path.t(), String.t() | nil) :: :ok | {:error, reason()}
  def check(path, passphrase) do
    with {:ok, _key} <- decode(path, passphrase), do: :ok
  end

  @spec user_key(atom(), keyword()) :: {:ok, :public_key.private_key()} | {:error, term()}
  def user_key(algorithm, opts) do
    key_opts = opts[:key_cb_private]

    with {:ok, key} <- decode(key_opts[:path], key_opts[:passphrase]) do
      if algorithm in algorithms(key), do: {:ok, key}, else: {:error, :no_key_found}
    end
  end

  defp decode(path, passphrase) do
    with {:ok, pem} <- LocalFiles.read(path),
         {:ok, key} <- decode_pem(pem, passphrase) do
      if algorithms(key) == [], do: {:error, :key_unreadable}, else: {:ok, key}
    end
  end

  defp decode_pem(@openssh_begin <> _ = pem, _passphrase) do
    case :ssh_file.decode(pem, :openssh_key_v1) do
      [{key, _attrs} | _] -> {:ok, key}
      _ -> {:error, openssh_error(pem)}
    end
  end

  defp decode_pem(pem, passphrase) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> decode_entry(entry, passphrase)
      [] -> {:error, :key_unreadable}
    end
  end

  defp decode_entry({_type, _der, :not_encrypted} = entry, _passphrase),
    do: safely(fn -> :public_key.pem_entry_decode(entry) end, :key_unreadable)

  defp decode_entry(_entry, nil), do: {:error, :key_passphrase_required}

  defp decode_entry(entry, passphrase) do
    safely(
      fn -> :public_key.pem_entry_decode(entry, String.to_charlist(passphrase)) end,
      :key_bad_passphrase
    )
  end

  defp safely(decode, error) do
    {:ok, decode.()}
  rescue
    _ -> {:error, error}
  end

  defp openssh_error(pem) do
    with [_, body | _] <- String.split(pem, [@openssh_begin, @openssh_end]),
         {:ok, <<"openssh-key-v1", 0, size::32, cipher::binary-size(size), _::binary>>}
         when cipher != "none" <- Base.decode64(body, ignore: :whitespace) do
      :key_encrypted_openssh
    else
      _ -> :key_unreadable
    end
  end

  defp algorithms(key) when elem(key, 0) == :RSAPrivateKey, do: @rsa_algorithms

  defp algorithms({:ECPrivateKey, _version, _private, {:namedCurve, oid}, _public, _attrs}),
    do: Map.get(@curve_algorithms, oid, [])

  defp algorithms(_key), do: []
end
