defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Fetches ETS record payloads from a remote node via `:voyager_agent`.

  Table metadata stays on `Voyager.Services.Ets.Remote`. These reads call
  `:ets_select_chunk/3` and `:ets_lookup/2` on the agent. A missing agent is
  `:undef` and drops the session. Truncation runs on the target.

  A continuation that crossed ETF must be repaired on the target against
  `[{:"$1", [], [:"$1"]}]` before `ets:select/1`. `badarg` (private table or
  unrepaired continuation) is `{:error, :cannot_read}`; a wrapped worker death
  is not.
  """

  alias Voyager.Agent
  alias Voyager.Services.Ets.TableId

  require TableId

  @chunk_sizes [10, 20, 50]
  @select_fun :ets_select_chunk
  @lookup_fun :ets_lookup

  @type lookup_key :: atom() | integer() | binary()

  @type chunk :: %{
          records: [term()],
          continuation: term() | nil
        }

  @spec select_chunk(node(), TableId.t(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(node, table, limit, continuation \\ nil, timeout \\ Agent.default_timeout())

  def select_chunk(node, table, limit, continuation, timeout)
      when TableId.is_table_id(table) do
    if limit in @chunk_sizes do
      cont = if is_nil(continuation), do: :undefined, else: continuation

      case Agent.call(node, @select_fun, [table, limit, cont], timeout) do
        {:ok, result} -> decode_select(result)
        {:error, _} = err -> map_read_error(err)
      end
    else
      {:error, :invalid_limit}
    end
  end

  def select_chunk(_node, _table, _limit, _continuation, _timeout), do: {:error, :invalid_table}

  @spec lookup(node(), TableId.t(), lookup_key(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, timeout \\ Agent.default_timeout())

  def lookup(node, table, key, timeout) when TableId.is_table_id(table) do
    if valid_key?(key) do
      case Agent.call(node, @lookup_fun, [table, key], timeout) do
        {:ok, result} -> decode_lookup(result)
        {:error, _} = err -> map_read_error(err)
      end
    else
      {:error, :invalid_key}
    end
  end

  def lookup(_node, _table, _key, _timeout), do: {:error, :invalid_table}

  defp decode_select(:"$end_of_table") do
    {:ok, %{records: [], continuation: nil}}
  end

  defp decode_select({records, :"$end_of_table"}) when is_list(records) do
    {:ok, %{records: records, continuation: nil}}
  end

  defp decode_select({records, continuation}) when is_list(records) do
    {:ok, %{records: records, continuation: continuation}}
  end

  defp decode_select(_other), do: {:error, :invalid_response}

  defp decode_lookup(records) when is_list(records) do
    {:ok, %{records: records, continuation: nil}}
  end

  defp decode_lookup(_other), do: {:error, :invalid_response}

  defp map_read_error({:error, {:remote_exception, :badarg}}), do: {:error, :cannot_read}
  defp map_read_error({:error, _} = err), do: err

  defp valid_key?(key) when is_atom(key) or is_integer(key) or is_binary(key), do: true
  defp valid_key?(_), do: false
end
