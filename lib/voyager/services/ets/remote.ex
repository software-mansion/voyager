defmodule Voyager.Services.Ets.Remote do
  @moduledoc """
  Fetches ETS table metadata and record payloads from a remote node.

  `:ets.info/1` includes private tables (`protection: :private`). `memory` is
  in bytes, using the target's `:erlang.system_info(:wordsize)`.

  Record reads probe `:voyager_agent` exports and fall back to OTP MFA only
  when those exports are missing. Heap kill, timeout, noconnection, and `undef`
  after a successful probe do not fall back. This module never injects code
  or calls `register/1`. Payloads are unsanitized; callers that surface terms
  must go through `Voyager.Services.Ets.Fetch`.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.TableId

  require TableId

  @chunk_sizes [10, 20, 50]
  @match_all [{:"$1", [], [:"$1"]}]
  @agent :voyager_agent
  @select_fun :ets_select_chunk
  @lookup_fun :ets_lookup

  @type protection :: :public | :protected | :private
  @type table_type :: :set | :ordered_set | :bag | :duplicate_bag
  @type via :: :mfa | :agent
  @type lookup_key :: atom() | integer() | binary()

  @type chunk :: %{
          records: [term()],
          continuation: term() | nil,
          via: via()
        }

  @type table_info :: %{
          required(:id) => TableId.t(),
          required(:name) => atom(),
          required(:named_table) => boolean(),
          required(:protection) => protection(),
          required(:type) => table_type(),
          required(:size) => non_neg_integer(),
          required(:memory) => non_neg_integer(),
          required(:owner) => pid(),
          required(:heir) => pid() | :none,
          required(:keypos) => pos_integer(),
          required(:compressed) => boolean(),
          required(:read_concurrency) => boolean(),
          required(:write_concurrency) => boolean() | :auto,
          optional(:decentralized_counters) => boolean()
        }

  @doc """
  Returns metadata for every live ETS table on `node`.

  Tables that disappear between `:ets.all/0` and `:ets.info/1` (`:undefined`)
  or return malformed info are dropped.
  """
  @spec list(node(), timeout()) :: {:ok, [table_info()]} | {:error, term()}
  def list(node, timeout \\ Erpc.default_timeout()) do
    case Erpc.safe_call(node, :ets, :all, [], timeout) do
      {:ok, ids} when is_list(ids) -> fetch_infos(node, ids, timeout)
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns metadata for a single table on `node`.

  Returns `{:error, :not_found}` when `:ets.info/1` is `:undefined`.
  """
  @spec info(node(), TableId.t(), timeout()) :: {:ok, table_info()} | {:error, term()}
  def info(node, table, timeout \\ Erpc.default_timeout())

  def info(node, table, timeout) when TableId.is_table_id(table) do
    with {:ok, info} when is_list(info) <- Erpc.safe_call(node, :ets, :info, [table], timeout),
         {:ok, word_size} when is_integer(word_size) and word_size > 0 <-
           Erpc.safe_call(node, :erlang, :system_info, [:wordsize], timeout) do
      case build(table, info, word_size) do
        {:ok, table_info} -> {:ok, table_info}
        :error -> {:error, :invalid_response}
      end
    else
      {:ok, :undefined} -> {:error, :not_found}
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  def info(_node, _table, _timeout), do: {:error, :invalid_table}

  @doc """
  Match-all page of records. Missing agent export falls back to `:ets.select/3`
  for the first page only; later MFA pages are `{:error, :cannot_page}`.

  A continuation that crossed ETF must be `:ets.repair_continuation/2`'d on
  the target against `[{:"$1", [], [:"$1"]}]`; a spec compiled here is
  invalidated on the way back.

  `ets_select_chunk/3` (and `ets_lookup/2`) run in a one-shot worker. A
  `badarg` there — private table or unrepaired continuation — must be
  re-raised as `error:badarg` in the erpc process. This mapper only
  recognizes `{:remote_exception, :badarg}`. Wrapping the worker death
  (`{:agent_worker_down, {:badarg, _}}`) or letting `spawn_link` kill the
  apply process does not become `{:error, :cannot_read}`.
  """
  @spec select_chunk(node(), TableId.t(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(node, table, limit, continuation \\ nil, timeout \\ Erpc.default_timeout())

  def select_chunk(node, table, limit, continuation, timeout)
      when TableId.is_table_id(table) do
    if limit in @chunk_sizes do
      select(node, table, limit, continuation, timeout)
    else
      {:error, :invalid_limit}
    end
  end

  def select_chunk(_node, _table, _limit, _continuation, _timeout), do: {:error, :invalid_table}

  @spec lookup(node(), TableId.t(), lookup_key(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, timeout \\ Erpc.default_timeout())

  def lookup(node, table, key, timeout) when TableId.is_table_id(table) do
    if valid_key?(key) do
      case probe_export(node, @lookup_fun, 2, timeout) do
        {:ok, true} -> agent_lookup(node, table, key, timeout)
        {:ok, false} -> mfa_lookup(node, table, key, timeout)
        {:error, _} = err -> err
      end
    else
      {:error, :invalid_key}
    end
  end

  def lookup(_node, _table, _key, _timeout), do: {:error, :invalid_table}

  defp select(node, table, limit, continuation, timeout) do
    case probe_export(node, @select_fun, 3, timeout) do
      {:ok, true} -> agent_select(node, table, limit, continuation, timeout)
      {:ok, false} -> mfa_select(node, table, limit, continuation, timeout)
      {:error, _} = err -> err
    end
  end

  defp agent_select(node, table, limit, continuation, timeout) do
    cont = if is_nil(continuation), do: :undefined, else: continuation

    case Erpc.safe_call(node, @agent, @select_fun, [table, limit, cont], timeout) do
      {:ok, result} -> decode_select(result, :agent)
      {:error, _} = err -> map_read_error(err)
    end
  end

  # MFA cannot repair_continuation+select in one call, so later pages need the agent.
  defp mfa_select(_node, _table, _limit, continuation, _timeout)
       when not is_nil(continuation) do
    {:error, :cannot_page}
  end

  defp mfa_select(node, table, limit, nil, timeout) do
    case Erpc.safe_call(node, :ets, :select, [table, @match_all, limit], timeout) do
      {:ok, decoded} -> decode_select(decoded, :mfa)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp agent_lookup(node, table, key, timeout) do
    case Erpc.safe_call(node, @agent, @lookup_fun, [table, key], timeout) do
      {:ok, result} -> decode_lookup(result, :agent)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp mfa_lookup(node, table, key, timeout) do
    case Erpc.safe_call(node, :ets, :lookup, [table, key], timeout) do
      {:ok, result} -> decode_lookup(result, :mfa)
      {:error, _} = err -> map_read_error(err)
    end
  end

  defp decode_select(:"$end_of_table", via) do
    {:ok, %{records: [], continuation: nil, via: via}}
  end

  defp decode_select({records, :"$end_of_table"}, via) when is_list(records) do
    {:ok, %{records: records, continuation: nil, via: via}}
  end

  defp decode_select({records, continuation}, via) when is_list(records) do
    {:ok, %{records: records, continuation: continuation, via: via}}
  end

  defp decode_select(_other, _via), do: {:error, :invalid_response}

  defp decode_lookup(records, via) when is_list(records) do
    {:ok, %{records: records, continuation: nil, via: via}}
  end

  defp decode_lookup(_other, _via), do: {:error, :invalid_response}

  defp map_read_error({:error, {:remote_exception, :badarg}}), do: {:error, :cannot_read}
  defp map_read_error({:error, _} = err), do: err

  defp probe_export(node, fun, arity, timeout) do
    case Erpc.safe_call(node, :erlang, :function_exported, [@agent, fun, arity], timeout) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:ok, false}
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp valid_key?(key) when is_atom(key) or is_integer(key) or is_binary(key), do: true
  defp valid_key?(_), do: false

  defp fetch_infos(_node, [], _timeout), do: {:ok, []}

  defp fetch_infos(node, ids, timeout) do
    with {:ok, word_size} when is_integer(word_size) and word_size > 0 <-
           Erpc.safe_call(node, :erlang, :system_info, [:wordsize], timeout),
         {:ok, infos} when is_list(infos) and length(infos) == length(ids) <-
           Erpc.safe_call(node, :lists, :map, [&:ets.info/1, ids], timeout) do
      {:ok, zip_infos(ids, infos, word_size)}
    else
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp zip_infos(ids, infos, word_size) do
    ids
    |> Enum.zip(infos)
    |> Enum.flat_map(fn
      {_id, :undefined} ->
        []

      {id, info} when is_list(info) ->
        case build(id, info, word_size) do
          {:ok, table} -> [table]
          :error -> []
        end

      {_id, _} ->
        []
    end)
  end

  defp build(id, info, word_size) do
    with true <- Keyword.keyword?(info),
         info = Map.new(info),
         {:ok, name} when is_atom(name) <- Map.fetch(info, :name),
         {:ok, named_table} when is_boolean(named_table) <- Map.fetch(info, :named_table),
         {:ok, protection} when protection in [:public, :protected, :private] <-
           Map.fetch(info, :protection),
         {:ok, type} when type in [:set, :ordered_set, :bag, :duplicate_bag] <-
           Map.fetch(info, :type),
         {:ok, size} when is_integer(size) and size >= 0 <- Map.fetch(info, :size),
         {:ok, memory} when is_integer(memory) and memory >= 0 <- Map.fetch(info, :memory),
         {:ok, owner} when is_pid(owner) <- Map.fetch(info, :owner),
         {:ok, heir} when heir == :none or is_pid(heir) <- Map.fetch(info, :heir),
         {:ok, keypos} when is_integer(keypos) and keypos >= 1 <- Map.fetch(info, :keypos),
         {:ok, compressed} when is_boolean(compressed) <- Map.fetch(info, :compressed),
         {:ok, read_concurrency} when is_boolean(read_concurrency) <-
           Map.fetch(info, :read_concurrency),
         {:ok, write_concurrency}
         when is_boolean(write_concurrency) or write_concurrency == :auto <-
           Map.fetch(info, :write_concurrency) do
      table = %{
        id: id,
        name: name,
        named_table: named_table,
        protection: protection,
        type: type,
        size: size,
        memory: memory * word_size,
        owner: owner,
        heir: heir,
        keypos: keypos,
        compressed: compressed,
        read_concurrency: read_concurrency,
        write_concurrency: write_concurrency
      }

      {:ok, put_decentralized_counters(table, info)}
    else
      _ -> :error
    end
  end

  defp put_decentralized_counters(table, info) do
    case Map.fetch(info, :decentralized_counters) do
      {:ok, value} when is_boolean(value) -> Map.put(table, :decentralized_counters, value)
      _ -> table
    end
  end
end
