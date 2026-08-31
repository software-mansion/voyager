defmodule Voyager.Services.Ets.Remote do
  @moduledoc """
  Fetches ETS table metadata and record payloads from a remote node.

  Listing is cheap and bounded: one `:ets.all/0` and one `:lists.map` of
  `:ets.info/1`. Record reads (`select_chunk` / `lookup`) probe
  `:voyager_agent` **exports** (`ets_select_chunk/3`, `ets_lookup/2`) and
  fall back to OTP MFA only when those exports are missing. Heap kill,
  timeout, noconnection, and `undef` after a successful probe do **not**
  fall back to MFA. This module never injects code or calls `register/1`.

  `:ets.info/1` includes private tables (`protection: :private`). `memory` is
  in bytes, using the target's `:erlang.system_info(:wordsize)`.

  Record payloads are unsanitized. Callers that surface terms must go
  through `Voyager.Services.Ets.Fetch`. Paging is best-effort; there is
  no snapshot isolation.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.TableId

  require TableId

  @default_timeout 5_000
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
  Returns a match-all page of records from `table` on `node`.

  `limit` must be 10, 20, or 50. `continuation` is `nil` for the first page
  and the opaque ETS continuation from a prior chunk afterwards. Missing
  `:voyager_agent.ets_select_chunk/3` falls back to `:ets.select/3` (first
  page) or `:ets.select/1` (later pages). Paging is best-effort.
  """
  @spec select_chunk(node(), TableId.t(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(node, table, limit, continuation \\ nil, timeout \\ @default_timeout)

  def select_chunk(node, table, limit, continuation, timeout)
      when is_atom(table) or is_reference(table) do
    if limit in @chunk_sizes do
      select(node, table, @match_all, limit, continuation, timeout)
    else
      {:error, :invalid_limit}
    end
  end

  def select_chunk(_node, _table, _limit, _continuation, _timeout), do: {:error, :invalid_table}

  @doc """
  Looks up `key` in `table` on `node`.

  Keys in this cut: atom, integer, or binary. Missing
  `:voyager_agent.ets_lookup/2` falls back to `:ets.lookup/2`.
  """
  @spec lookup(node(), TableId.t(), lookup_key(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, timeout \\ @default_timeout)

  def lookup(node, table, key, timeout) when is_atom(table) or is_reference(table) do
    if valid_key?(key) do
      case exported?(node, @lookup_fun, 2, timeout) do
        {:ok, true} -> agent_lookup(node, table, key, timeout)
        {:ok, false} -> mfa_lookup(node, table, key, timeout)
        {:error, _} = err -> err
      end
    else
      {:error, :invalid_key}
    end
  end

  def lookup(_node, _table, _key, _timeout), do: {:error, :invalid_table}

  # Shared by `select_chunk/5` (match-all) so VOY-231 can reuse the probe
  # without forking fallback rules.
  defp select(node, table, match_spec, limit, continuation, timeout) do
    case exported?(node, @select_fun, 3, timeout) do
      {:ok, true} -> agent_select(node, table, limit, continuation, timeout)
      {:ok, false} -> mfa_select(node, table, match_spec, limit, continuation, timeout)
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

  defp mfa_select(node, table, match_spec, limit, continuation, timeout) do
    result =
      if is_nil(continuation) do
        Erpc.safe_call(node, :ets, :select, [table, match_spec, limit], timeout)
      else
        Erpc.safe_call(node, :ets, :select, [continuation], timeout)
      end

    case result do
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

  defp exported?(node, fun, arity, timeout) do
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
