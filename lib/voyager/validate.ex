defmodule Voyager.Validate do
  @moduledoc """
  Validates `host` and node-name values before they are passed to Erlang's
  `:ssh` client or converted to atoms.

  Every value is capped at 255 bytes so that names later passed to
  `String.to_atom/1` stay within the atom limit and cannot raise `system_limit`.
  """

  @max_len 255

  @host_re ~r/\A[A-Za-z0-9:][A-Za-z0-9._:-]*\z/
  @name_re ~r/\A[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+\z/

  @spec host(String.t()) :: :ok | {:error, {:invalid_host, String.t()}}
  def host(host) when is_binary(host) do
    if safe?(host, @host_re), do: :ok, else: {:error, {:invalid_host, host}}
  end

  @spec node_name(String.t()) :: :ok | {:error, {:invalid_node_name, String.t()}}
  def node_name(name) when is_binary(name) do
    if safe?(name, @name_re), do: :ok, else: {:error, {:invalid_node_name, name}}
  end

  defp safe?(value, re) do
    value != "" and byte_size(value) <= @max_len and Regex.match?(re, value)
  end
end
