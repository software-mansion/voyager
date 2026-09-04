defmodule Voyager.Services.Ets.Search do
  @moduledoc """
  Compiles key-prefix / field-equals queries into source ETS match specs.

  Never evals user or LLM strings. Records go through `Fetch.select_spec/6`
  (host heap isolate + sanitize). The spec sent on the wire is a source MS,
  not `:ets.match_spec_compile/1`.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Services.Ets.TableId

  require TableId

  @type scalar :: atom() | integer() | binary()

  @type query ::
          {:key_eq, scalar()}
          | {:key_prefix, binary()}
          | {:element_eq, pos_integer(), scalar()}

  @type spec :: [{term(), [term()], [term()]}]

  @type chunk :: Remote.chunk()

  @spec compile(query(), pos_integer()) :: {:ok, spec()} | {:error, :invalid_query}
  def compile(query, keypos \\ 1)

  def compile({:key_eq, value}, keypos) when is_integer(keypos) and keypos >= 1 do
    eq_query(keypos, value)
  end

  def compile({:key_prefix, prefix}, keypos)
      when is_integer(keypos) and keypos >= 1 and is_binary(prefix) do
    prefix_query(keypos, prefix)
  end

  def compile({:element_eq, index, value}, _keypos) when is_integer(index) and index >= 1 do
    eq_query(index, value)
  end

  def compile(_query, _keypos), do: {:error, :invalid_query}

  @spec chunk(node(), TableId.t(), query(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def chunk(node, table, query, limit, continuation \\ nil, timeout \\ Erpc.default_timeout())

  def chunk(node, table, query, limit, continuation, timeout) when TableId.is_table_id(table) do
    with :ok <- validate_query(query),
         {:ok, keypos} <- keypos_for(node, table, query, timeout),
         {:ok, spec} <- compile(query, keypos) do
      Fetch.select_spec(node, table, spec, limit, continuation, timeout)
    end
  end

  def chunk(_node, _table, _query, _limit, _continuation, _timeout), do: {:error, :invalid_table}

  defp validate_query({:key_eq, value}) do
    if valid_scalar?(value), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_query({:key_prefix, prefix}) when is_binary(prefix) do
    prefix_query(1, prefix) |> query_ok()
  end

  defp validate_query({:element_eq, index, value}) when is_integer(index) and index >= 1 do
    if valid_scalar?(value), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_query(_), do: {:error, :invalid_query}

  defp query_ok({:ok, _}), do: :ok
  defp query_ok({:error, _} = err), do: err

  defp keypos_for(node, table, {:key_eq, _}, timeout), do: fetch_keypos(node, table, timeout)
  defp keypos_for(node, table, {:key_prefix, _}, timeout), do: fetch_keypos(node, table, timeout)
  defp keypos_for(_node, _table, {:element_eq, _, _}, _timeout), do: {:ok, 1}

  defp fetch_keypos(node, table, timeout) do
    case Remote.info(node, table, timeout) do
      {:ok, %{keypos: keypos}} when is_integer(keypos) and keypos >= 1 -> {:ok, keypos}
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp eq_query(pos, value) do
    if valid_scalar?(value) do
      {:ok, [{:"$1", [{:"=:=", {:element, pos, :"$1"}, value}], [:"$1"]}]}
    else
      {:error, :invalid_query}
    end
  end

  defp prefix_query(pos, prefix) do
    size = byte_size(prefix)

    cond do
      size == 0 ->
        {:error, :invalid_query}

      size > Sanitize.max_binary_bytes() ->
        {:error, :invalid_query}

      true ->
        key = {:element, pos, :"$1"}

        {:ok,
         [
           {:"$1",
            [
              {:is_binary, key},
              {:>=, {:byte_size, key}, size},
              {:"=:=", {:binary_part, key, 0, size}, prefix}
            ], [:"$1"]}
         ]}
    end
  end

  defp valid_scalar?(value) when is_atom(value) or is_integer(value) or is_binary(value), do: true
  defp valid_scalar?(_), do: false
end
