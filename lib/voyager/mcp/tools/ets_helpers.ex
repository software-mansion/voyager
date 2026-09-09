defmodule Voyager.MCP.Tools.EtsHelpers do
  @moduledoc false

  @spec parse_table(String.t()) :: {:ok, atom() | reference()} | {:error, atom()}
  def parse_table("#Ref<" <> _ = ref_str) do
    {:ok, :erlang.list_to_ref(String.to_charlist(ref_str))}
  rescue
    ArgumentError -> {:error, :invalid_table_ref}
  end

  def parse_table("#Reference<" <> _ = ref_str) do
    # Elixir inspect prints "#Reference<...>", while Erlang ref_to_list produces "#Ref<...>"
    erl_ref_str = "#Ref<" <> String.trim_leading(ref_str, "#Reference<")
    {:ok, :erlang.list_to_ref(String.to_charlist(erl_ref_str))}
  rescue
    ArgumentError -> {:error, :invalid_table_ref}
  end

  def parse_table(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :invalid_table_name}
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
