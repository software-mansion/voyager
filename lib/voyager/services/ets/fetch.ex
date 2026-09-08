defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Fetches ETS record payloads from a remote node via `:voyager_agent`.

  Table metadata stays on `Voyager.Services.Ets.Remote`. These reads call
  `:ets_select_chunk/4` and `:ets_lookup/3` on the agent. A missing agent is
  `:undef` and drops the session. Truncation and the worker heap cap run on
  the target. Each record is walked independently with the caller's term
  `budget` (see `Voyager.Agent.default_budget/0`).

  A continuation that crossed ETF must be repaired on the target against
  `[{:"$1", [], [:"$1"]}]` before `ets:select/1`. `badarg` (private table or
  unrepaired continuation) is `{:error, :cannot_read}`; a wrapped worker death
  is not. A remote worker heap kill is `{:error, :heap_limit_exceeded}`.
  """

  alias Voyager.Agent
  alias Voyager.Services.Ets.TableId

  require TableId

  @chunk_sizes [1, 2, 5, 10, 20, 50]
  @budget Agent.default_budget()
  @select_fun :ets_select_chunk
  @lookup_fun :ets_lookup

  @type lookup_key :: atom() | integer() | binary()
  @type limit :: 10 | 20 | 50

  @type chunk :: %{
          records: [term()],
          continuation: term() | nil,
          truncated?: boolean()
        }

  @spec chunk_sizes() :: [limit(), ...]
  def chunk_sizes, do: @chunk_sizes

  @spec select_chunk(node(), TableId.t(), limit(), non_neg_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(
        node,
        table,
        limit,
        budget \\ @budget,
        continuation \\ nil,
        timeout \\ Agent.default_timeout()
      )

  def select_chunk(node, table, limit, budget, continuation, timeout)
      when TableId.is_table_id(table) and is_integer(budget) and budget >= 0 do
    if limit in @chunk_sizes do
      cont = if is_nil(continuation), do: :undefined, else: continuation
      fetch_chunk(node, @select_fun, [table, limit, budget, cont], timeout)
    else
      {:error, :invalid_limit}
    end
  end

  def select_chunk(_node, table, _limit, _budget, _continuation, _timeout)
      when TableId.is_table_id(table) do
    {:error, :invalid_budget}
  end

  def select_chunk(_node, _table, _limit, _budget, _continuation, _timeout),
    do: {:error, :invalid_table}

  @spec lookup(node(), TableId.t(), lookup_key(), non_neg_integer(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, budget \\ @budget, timeout \\ Agent.default_timeout())

  def lookup(node, table, key, budget, timeout)
      when TableId.is_table_id(table) and is_integer(budget) and budget >= 0 do
    if valid_key?(key) do
      fetch_chunk(node, @lookup_fun, [table, key, budget], timeout)
    else
      {:error, :invalid_key}
    end
  end

  def lookup(_node, table, _key, _budget, _timeout) when TableId.is_table_id(table) do
    {:error, :invalid_budget}
  end

  def lookup(_node, _table, _key, _budget, _timeout), do: {:error, :invalid_table}

  defp fetch_chunk(node, fun, args, timeout) do
    case Agent.fetch(node, fun, args, timeout) do
      {:ok, payload} -> decode_chunk(payload)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp decode_chunk(%{records: records, continuation: continuation, truncated?: truncated?})
       when is_list(records) and is_boolean(truncated?) do
    {:ok,
     %{
       records: records,
       continuation: normalize_cont(continuation),
       truncated?: truncated?
     }}
  end

  defp decode_chunk(_other), do: {:error, :invalid_response}

  defp normalize_cont(cont) when cont in [nil, :undefined, :"$end_of_table"], do: nil
  defp normalize_cont(cont), do: cont

  defp map_read_error({:error, {:remote_exception, :badarg}}), do: {:error, :cannot_read}
  defp map_read_error({:error, {:remote_exception, :killed}}), do: {:error, :heap_limit_exceeded}

  defp map_read_error({:error, {:remote_exception, {:killed, _}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_read_error({:error, _} = err), do: err

  defp valid_key?(key) when is_atom(key) or is_integer(key) or is_binary(key), do: true
  defp valid_key?(_), do: false
end
