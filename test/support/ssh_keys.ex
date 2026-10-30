defmodule Voyager.Test.SshKeys do
  @moduledoc "Throwaway SSH private keys in a test's `tmp_dir`; each helper returns `{path, public_key}`."

  @spec ssh_keygen!(Path.t(), String.t(), [String.t()]) :: {Path.t(), :public_key.public_key()}
  def ssh_keygen!(dir, name, args) do
    path = Path.join(dir, name)
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-C", "", "-f", path | args], stderr_to_stdout: true)
    [{public_key, _attrs}] = :ssh_file.decode(File.read!(path <> ".pub"), :public_key)
    {path, public_key}
  end

  @spec pem!(Path.t(), String.t(), :public_key.private_key(), String.t() | nil) ::
          {Path.t(), :public_key.public_key()}
  def pem!(dir, name, key, passphrase \\ nil) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode([pem_entry(key, passphrase)]))
    {path, :ssh_file.extract_public_key(key)}
  end

  defp pem_entry(key, nil), do: :public_key.pem_entry_encode(elem(key, 0), key)

  defp pem_entry(key, passphrase) do
    cipher = {~c"AES-128-CBC", :crypto.strong_rand_bytes(16)}
    :public_key.pem_entry_encode(elem(key, 0), key, {cipher, String.to_charlist(passphrase)})
  end
end
