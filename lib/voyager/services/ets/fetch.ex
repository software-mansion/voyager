defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Fetches ETS record payloads from a remote node via the remote agent.

  Table metadata stays on `Voyager.Services.Ets.Remote`. These reads call
  `:ets_select_chunk/4`, `:ets_select_spec/5`, and `:ets_lookup/5` on the agent.
  A missing agent is `:undef` and drops the session. Truncation and the heap cap
  run on the target. Each record is walked independently with the caller's term
  `budget` (see `Voyager.Agent.default_budget/0`).

  `lookup/7` pages a single key with the same positive limit as select. A bag
  or duplicate_bag key that holds more objects than the limit returns
  `{:"$voyager_skip", Skip}` for the rest of that key, never the key's unread
  objects. A bag key estimated above ~1M words is refused with
  `{:error, :key_too_large}` before any row is copied.

  A select continuation that crossed ETF must be repaired on the target against
  the same match spec used for the page (`[{:"$1", [], [:"$1"]}]` for match-all;
  `ets_select_spec` uses the caller spec). Bag lookup resumes from the skip
  count without `ets:repair_continuation/2`. `badarg` (private table, bad spec,
  unrepaired continuation, out-of-range budget) is `{:error, :cannot_read}`.
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

  def select_chunk(node, table, limit, budget, continuation, timeout) do
    args = [table, limit, budget, continuation || :undefined]
    fetch_chunk(node, :ets_select_chunk, args, limit, timeout)
  end

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

  def select_spec(node, table, spec, limit, budget, continuation, timeout) do
    args = [table, spec, limit, budget, continuation || :undefined]
    fetch_chunk(node, :ets_select_spec, args, limit, timeout)
  end

  @spec lookup(
          node(),
          TableId.t(),
          term(),
          pos_integer(),
          non_neg_integer(),
          term() | nil,
          timeout()
        ) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(
        node,
        table,
        key,
        limit,
        budget \\ @budget,
        continuation \\ nil,
        timeout \\ Agent.default_timeout()
      )

  def lookup(node, table, key, limit, budget, continuation, timeout) do
    args = [table, key, limit, budget, continuation || :undefined]
    fetch_chunk(node, :ets_lookup, args, limit, timeout)
  end

  defp fetch_chunk(node, fun, [table | _] = args, limit, timeout)
       when TableId.is_table_id(table) and is_integer(limit) and limit > 0 do
    case Agent.fetch(node, fun, args, timeout) do
      {:ok, payload} -> decode_chunk(payload)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp fetch_chunk(_node, _fun, [table | _], _limit, _timeout) when TableId.is_table_id(table),
    do: {:error, :invalid_limit}

  defp fetch_chunk(_node, _fun, _args, _limit, _timeout), do: {:error, :invalid_table}

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
