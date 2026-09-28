defmodule Voyager.Services.Ets.Search do
  @moduledoc """
  Compiles key-prefix / field-equals queries into source ETS match specs.

  Never evals user or LLM strings. Prefix and element queries go through
  `Fetch.select_spec/7`. `{:key_eq, _}` goes through `Fetch.lookup/7` so the
  key stays a hash lookup on the target, still honouring limit and continuation.
  The spec sent on the wire for prefix/element is a source MS, not
  `:ets.match_spec_compile/1`.
  """

  alias Voyager.Agent
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.TableId

  require TableId

  @max_prefix_bytes 512
  @budget Agent.default_budget()

  @type scalar :: atom() | integer() | binary()

  @type query ::
          {:key_eq, scalar()}
          | {:key_prefix, binary()}
          | {:element_eq, pos_integer(), scalar()}

  @type spec :: [{term(), [term()], [term()]}]

  @type chunk :: Fetch.chunk()

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

  @spec chunk(
          node(),
          TableId.t(),
          query(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          term() | nil,
          timeout()
        ) ::
          {:ok, chunk()} | {:error, term()}
  def chunk(
        node,
        table,
        query,
        keypos,
        limit,
        budget \\ @budget,
        continuation \\ nil,
        timeout \\ Agent.default_timeout()
      )

  def chunk(node, table, query, keypos, limit, budget, continuation, timeout)
      when TableId.is_table_id(table) and is_integer(budget) and budget >= 0 do
    with :ok <- validate_query(query),
         :ok <- validate_keypos(keypos),
         :ok <- validate_limit(limit) do
      run_query(node, table, query, keypos, limit, budget, continuation, timeout)
    end
  end

  def chunk(_node, table, _query, _keypos, _limit, _budget, _continuation, _timeout)
      when TableId.is_table_id(table) do
    {:error, :invalid_budget}
  end

  def chunk(_node, _table, _query, _keypos, _limit, _budget, _continuation, _timeout),
    do: {:error, :invalid_table}

  defp validate_query({:key_eq, value}) do
    if valid_scalar?(value), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_query({:key_prefix, prefix}) when is_binary(prefix) do
    if valid_prefix?(prefix), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_query({:element_eq, index, value}) when is_integer(index) and index >= 1 do
    if valid_scalar?(value), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_query(_), do: {:error, :invalid_query}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_limit(_limit), do: {:error, :invalid_limit}

  defp validate_keypos(keypos) when is_integer(keypos) and keypos >= 1, do: :ok
  defp validate_keypos(_keypos), do: {:error, :invalid_keypos}

  defp run_query(node, table, {:key_eq, value}, _keypos, limit, budget, continuation, timeout) do
    Fetch.lookup(node, table, value, limit, budget, continuation, timeout)
  end

  defp run_query(node, table, query, keypos, limit, budget, continuation, timeout) do
    with {:ok, spec} <- compile(query, keypos) do
      Fetch.select_spec(node, table, spec, limit, budget, continuation, timeout)
    end
  end

  defp eq_query(pos, value) do
    if valid_scalar?(value) do
      {:ok, [{:"$1", [{:"=:=", {:element, pos, :"$1"}, {:const, value}}], [:"$1"]}]}
    else
      {:error, :invalid_query}
    end
  end

  defp prefix_query(pos, prefix) do
    if valid_prefix?(prefix) do
      size = byte_size(prefix)
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
    else
      {:error, :invalid_query}
    end
  end

  defp valid_scalar?(value) when is_atom(value) or is_integer(value) or is_binary(value), do: true
  defp valid_scalar?(_), do: false

  defp valid_prefix?(prefix) when is_binary(prefix) do
    size = byte_size(prefix)
    size > 0 and size <= @max_prefix_bytes
  end
end
