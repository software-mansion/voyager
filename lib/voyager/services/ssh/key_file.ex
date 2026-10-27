defmodule Voyager.Services.SSH.KeyFile do
  @moduledoc false

  @behaviour :ssh_client_key_api

  alias Voyager.Services.LocalFiles
  alias Voyager.Services.SSH.OpensshKey

  require OpensshKey

  @type reason ::
          OpensshKey.reason()
          | {:read_failed, {Path.t(), File.posix()}}

  @rsa_algorithms [:"rsa-sha2-256", :"rsa-sha2-512", :"ssh-rsa"]

  @curve_algorithms %{
    {1, 3, 101, 112} => [:"ssh-ed25519"],
    {1, 3, 101, 113} => [:"ssh-ed448"],
    {1, 2, 840, 10_045, 3, 1, 7} => [:"ecdsa-sha2-nistp256"],
    {1, 3, 132, 0, 34} => [:"ecdsa-sha2-nistp384"],
    {1, 3, 132, 0, 35} => [:"ecdsa-sha2-nistp521"]
  }

  @doc "Decrypting an OpenSSH key takes seconds at the default bcrypt rounds; run it off the UI process."
  @spec decode(Path.t(), String.t() | nil) ::
          {:ok, :public_key.private_key()} | {:error, reason()}
  def decode(path, passphrase) do
    with {:ok, pem} <- LocalFiles.read(path),
         {:ok, key} <- decode_pem(pem, passphrase) do
      if algorithms(key) == [], do: {:error, :key_unreadable}, else: {:ok, key}
    end
  end

  @impl true
  def user_key(algorithm, opts) do
    key = opts[:key_cb_private][:key]
    if algorithm in algorithms(key), do: {:ok, key}, else: {:error, :no_key_found}
  end

  @impl true
  def is_host_key(key, host, port, algorithm, opts),
    do: :ssh_file.is_host_key(key, host, port, algorithm, opts)

  @impl true
  def add_host_key(host, port, key, opts), do: :ssh_file.add_host_key(host, port, key, opts)

  defp decode_pem(pem, passphrase) when OpensshKey.is_openssh_pem(pem) do
    case :ssh_file.decode(pem, :openssh_key_v1) do
      [{key, _attrs} | _] -> {:ok, key}
      _ -> OpensshKey.decrypt(pem, passphrase)
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

  defp algorithms(key) when elem(key, 0) == :RSAPrivateKey, do: @rsa_algorithms

  defp algorithms({:ECPrivateKey, _version, _private, {:namedCurve, oid}, _public, _attrs}),
    do: Map.get(@curve_algorithms, oid, [])

  defp algorithms(_key), do: []
end
