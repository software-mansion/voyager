defmodule Voyager.MCP.Tools.EtsHelpers do
  @moduledoc false

  alias Voyager.Erpc
  alias Voyager.Services.Ets.TableId

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
      {:error, :not_found} -> {:error, :invalid_table_name}
      {:error, :invalid_name} -> {:error, :invalid_table_name}
      {:error, _} = err -> err
    end
  end

  @spec format_chunk({:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def format_chunk({:ok, chunk}) do
    cursor = encode_cursor(Map.get(chunk, :continuation))

    formatted =
      chunk
      |> Map.delete(:continuation)
      |> Map.put(:cursor, cursor)

    {:ok, formatted}
  end

  def format_chunk(error), do: error

  @spec encode_cursor(term()) :: String.t() | nil
  def encode_cursor(nil), do: nil

  def encode_cursor(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.url_encode64()
  end

  @spec decode_cursor(String.t() | nil) :: {:ok, term()} | {:error, :invalid_cursor}
  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(string) when is_binary(string) do
    case Base.url_decode64(string) do
      {:ok, bin} ->
        try do
          {:ok, :erlang.binary_to_term(bin, [:safe])}
        rescue
          ArgumentError -> {:error, :invalid_cursor}
        end

      :error ->
        {:error, :invalid_cursor}
    end
  end
end
