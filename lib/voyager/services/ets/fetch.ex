defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Fetches ETS record payloads from a remote node via `:voyager_agent`.

  Table metadata stays on `Voyager.Services.Ets.Remote`. These reads call
  `:ets_select_chunk/4`, `:ets_select_spec/5`, and `:ets_lookup/3` on the agent.
  A missing agent is `:undef` and drops the session. Truncation and the heap cap
  run on the target. Each record is walked independently with the caller's term
  `budget` (see `Voyager.Agent.default_budget/0`).

  A continuation that crossed ETF must be repaired on the target against the
  same match spec used for the page (`[{:"$1", [], [:"$1"]}]` for match-all)
  before `ets:select/1`. `badarg` (private table, bad spec, unrepaired
  continuation, out-of-range budget) is `{:error, :cannot_read}`.
  """

  alias Voyager.Agent
  alias Voyager.Services.Ets.TableId

  require TableId

  @budget Agent.default_budget()

  @type chunk :: %{
          records: [term()],
          continuation: term() | nil,
          truncated?: boolean()
        }

  @spec select_chunk(
          node(),
          TableId.t(),
          pos_integer(),
          non_neg_integer(),
          term() | nil,
          timeout()
        ) :: {:ok, chunk()} | {:error, term()}
  def select_chunk(
        node,
        table,
        limit,
        budget \\ @budget,
        continuation \\ nil,
        timeout \\ Agent.default_timeout()
      )

  def select_chunk(node, table, limit, budget, continuation, timeout)
      when TableId.is_table_id(table) and is_integer(limit) and limit > 0 do
    cont = continuation || :undefined
    fetch_chunk(node, :ets_select_chunk, [table, limit, budget, cont], timeout)
  end

  def select_chunk(_node, table, _limit, _budget, _continuation, _timeout)
      when TableId.is_table_id(table) do
    {:error, :invalid_limit}
  end

  def select_chunk(_node, _table, _limit, _budget, _continuation, _timeout),
    do: {:error, :invalid_table}

  @spec select_spec(
          node(),
          TableId.t(),
          term(),
          pos_integer(),
          non_neg_integer(),
          term() | nil,
          timeout()
        ) ::
          {:ok, chunk()} | {:error, term()}
  def select_spec(
        node,
        table,
        spec,
        limit,
        budget \\ @budget,
        continuation \\ nil,
        timeout \\ Agent.default_timeout()
      )

  def select_spec(node, table, spec, limit, budget, continuation, timeout)
      when TableId.is_table_id(table) and is_integer(limit) and limit > 0 do
    cont = continuation || :undefined
    fetch_chunk(node, :ets_select_spec, [table, spec, limit, budget, cont], timeout)
  end

  def select_spec(_node, table, _spec, _limit, _budget, _continuation, _timeout)
      when TableId.is_table_id(table) do
    {:error, :invalid_limit}
  end

  def select_spec(_node, _table, _spec, _limit, _budget, _continuation, _timeout),
    do: {:error, :invalid_table}

  @spec lookup(node(), TableId.t(), term(), non_neg_integer(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, budget \\ @budget, timeout \\ Agent.default_timeout())

  def lookup(node, table, key, budget, timeout) when TableId.is_table_id(table) do
    fetch_chunk(node, :ets_lookup, [table, key, budget], timeout)
  end

  def lookup(_node, _table, _key, _budget, _timeout), do: {:error, :invalid_table}

  defp fetch_chunk(node, fun, args, timeout) do
    case Agent.fetch(node, fun, args, timeout) do
      {:ok, payload} -> decode_chunk(payload)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp decode_chunk(%{records: records, continuation: cont, truncated?: truncated?} = chunk)
       when is_list(records) and is_boolean(truncated?) do
    {:ok, %{chunk | continuation: normalize_cont(cont)}}
  end

  defp decode_chunk(_other), do: {:error, :invalid_response}

  defp normalize_cont(cont) when cont in [:undefined, :"$end_of_table"], do: nil
  defp normalize_cont(cont), do: cont

  defp map_read_error({:error, {:remote_exception, :badarg}}), do: {:error, :cannot_read}
  defp map_read_error({:error, _} = err), do: err
end
