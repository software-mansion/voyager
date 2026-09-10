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

  @spec format_chunk({:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def format_chunk({:ok, chunk}) do
    {continuation, rest} = Map.pop(chunk, :continuation)
    {:ok, Map.put(rest, :cursor, encode_cursor(continuation))}
  end

  def format_chunk(error), do: error

  @spec encode_cursor(term()) :: String.t() | nil
  def encode_cursor(nil), do: nil

  def encode_cursor(term), do: Plug.Crypto.sign(secret(), @cursor_salt, term)

  @spec decode_cursor(String.t() | nil) :: {:ok, term()} | {:error, :invalid_cursor}
  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(string) when is_binary(string) and byte_size(string) <= @max_cursor_bytes do
    case Plug.Crypto.verify(secret(), @cursor_salt, string) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_string), do: {:error, :invalid_cursor}

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
