defmodule Voyager.Validate do
  @moduledoc """
  Validates `host`, node-name, and `epmd`-path values before they are passed to
  Erlang's `:ssh` client, interpolated into the remote `epmd -names` command, or
  converted to atoms.

  Every value is capped at 255 bytes so that names later passed to
  `String.to_atom/1` stay within the atom limit and cannot raise `system_limit`.

  `epmd_prefix` is trusted operator input (it runs over an SSH session that
  already grants full remote shell access), so it intentionally permits shell
  env-var assignments and paths such as `PATH=$HOME/.local/bin:$PATH`. The
  allowlist still rejects command-chaining and substitution metacharacters
  (`;`, `|`, `&`, backtick, parentheses, redirections, quotes, newlines) as
  defense-in-depth should the value ever come from a saved profile.
  """

  @max_len 255

  @host_re ~r/\A[A-Za-z0-9._:-]+\z/
  @name_re ~r/\A[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+\z/
  @prefix_re ~r{\A[A-Za-z0-9_.:/=$~@-]+\z}

  @spec host(String.t()) :: :ok | {:error, {:invalid_host, String.t()}}
  def host(host) when is_binary(host) do
    if safe?(host, @host_re), do: :ok, else: {:error, {:invalid_host, host}}
  end

  @spec node_name(String.t()) :: :ok | {:error, {:invalid_node_name, String.t()}}
  def node_name(name) when is_binary(name) do
    if safe?(name, @name_re), do: :ok, else: {:error, {:invalid_node_name, name}}
  end

  @spec epmd_prefix(String.t()) :: :ok | {:error, {:invalid_epmd_prefix, String.t()}}
  def epmd_prefix(prefix) when is_binary(prefix) do
    if safe_prefix?(prefix), do: :ok, else: {:error, {:invalid_epmd_prefix, prefix}}
  end

  defp safe_prefix?(prefix) do
    prefix == "" or (byte_size(prefix) <= @max_len and Regex.match?(@prefix_re, prefix))
  end

  defp safe?(value, re) do
    value != "" and byte_size(value) <= @max_len and Regex.match?(re, value)
  end
end
