defmodule Voyager.Services.OpenSSH.Validate do
  @moduledoc """
  Validates `user`, `host`, and node-name values before they are passed as
  positional arguments to the OpenSSH binaries or converted to atoms.

  OpenSSH parses any argument beginning with `-` as an option, so an
  unvalidated `host`/`user` such as `-oProxyCommand=...` would let a caller
  inject ssh options — including local command execution via `ProxyCommand`.
  These helpers reject such values up front. The length cap also keeps node
  names within the 255-byte atom limit so `String.to_atom/1` cannot raise
  `system_limit`.
  """

  @max_len 255

  @host_re ~r/\A[A-Za-z0-9._:-]+\z/
  @name_re ~r/\A[A-Za-z0-9._-]+\z/

  @spec host(String.t()) :: {:ok, String.t()} | {:error, {:invalid_host, String.t()}}
  def host(host) when is_binary(host) do
    if safe?(host, @host_re), do: {:ok, host}, else: {:error, {:invalid_host, host}}
  end

  @spec user(String.t()) :: {:ok, String.t()} | {:error, {:invalid_user, String.t()}}
  def user(user) when is_binary(user) do
    if safe?(user, @name_re), do: {:ok, user}, else: {:error, {:invalid_user, user}}
  end

  @spec node_name(String.t()) :: {:ok, String.t()} | {:error, {:invalid_node_name, String.t()}}
  def node_name(name) when is_binary(name) do
    if safe?(name, @name_re), do: {:ok, name}, else: {:error, {:invalid_node_name, name}}
  end

  defp safe?(value, re) do
    value != "" and byte_size(value) <= @max_len and
      not String.starts_with?(value, "-") and Regex.match?(re, value)
  end
end
