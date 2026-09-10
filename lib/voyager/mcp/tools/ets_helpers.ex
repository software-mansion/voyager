defmodule Voyager.MCP.Tools.EtsHelpers do
  @moduledoc false

  alias Voyager.Erpc
  alias Voyager.Services.Ets.TableId

  @cursor_salt "ets cursor"
  @max_cursor_bytes 16_384
  @secret_key {__MODULE__, :cursor_secret}

  # Refs are rebuilt with :erlang.list_to_ref/1 instead of TableId.resolve/4 to
  # avoid an ets:all round-trip per read; a stale ref fails on the target as
  # :cannot_read.
  @spec parse_table(node(), String.t()) :: {:ok, TableId.t()} | {:error, term()}
  def parse_table(_node, "#Ref" <> _ = ref_str) do
    ref =
      ref_str
      |> String.replace_prefix("#Reference<", "#Ref<")
      |> String.to_charlist()
      |> :erlang.list_to_ref()

    {:ok, ref}
  rescue
    ArgumentError -> {:error, :invalid_table_ref}
  end

  def parse_table(node, name) when is_binary(name) do
    case TableId.existing_atom(node, name, Erpc.default_timeout()) do
      {:ok, atom} -> {:ok, atom}
      {:error, e} when e in [:not_found, :invalid_name] -> {:error, :invalid_table_name}
      {:error, _} = err -> err
    end
  end

  @spec format_chunk({:ok, map()} | {:error, term()}, term()) :: {:ok, map()} | {:error, term()}
  def format_chunk({:ok, chunk}, scope) do
    {continuation, rest} = Map.pop(chunk, :continuation)
    {:ok, Map.put(rest, :cursor, encode_cursor(continuation, scope))}
  end

  def format_chunk(error, _scope), do: error

  # The scope is signed into the cursor because the target ignores the request's
  # table and spec once a continuation is present (ets:repair_continuation/2
  # swaps the spec in unchecked) — changed parameters would silently misread.
  @spec encode_cursor(term(), term()) :: String.t() | nil
  def encode_cursor(nil, _scope), do: nil

  def encode_cursor(continuation, scope),
    do: Plug.Crypto.sign(secret(), @cursor_salt, {scope, continuation})

  @spec decode_cursor(String.t() | nil, term()) ::
          {:ok, term()} | {:error, :invalid_cursor | :cursor_mismatch}
  def decode_cursor(nil, _scope), do: {:ok, nil}

  def decode_cursor(string, scope)
      when is_binary(string) and byte_size(string) <= @max_cursor_bytes do
    case Plug.Crypto.verify(secret(), @cursor_salt, string) do
      {:ok, {^scope, continuation}} -> {:ok, continuation}
      {:ok, _other} -> {:error, :cursor_mismatch}
      {:error, _} -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_string, _scope), do: {:error, :invalid_cursor}

  # The MAC ensures only host-signed cursors are ever term-decoded. A per-boot
  # key suffices: a continuation never outlives the session that issued it.
  defp secret do
    case :persistent_term.get(@secret_key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32)
        :persistent_term.put(@secret_key, secret)
        secret

      secret ->
        secret
    end
  end
end
