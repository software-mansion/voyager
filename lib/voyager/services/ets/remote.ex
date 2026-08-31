defmodule Voyager.Services.Ets.Remote do
  @moduledoc """
  Fetches ETS **table metadata** from a remote node via OTP MFA (`Voyager.Erpc`).

  Listing is cheap and bounded: one `:ets.all/0` and one `:lists.map` of
  `:ets.info/1`. Record payloads (`select` / `lookup`) are out of scope.
  This module does not inject or call `:voyager_agent`.

  `:ets.info/1` includes **private** tables; they are flagged via
  `protection: :private` and are not omitted. `memory` is converted to
  **bytes** using the target's `:erlang.system_info(:wordsize)`.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.TableId

  @default_timeout 5_000

  @type protection :: :public | :protected | :private
  @type table_type :: :set | :ordered_set | :bag | :duplicate_bag

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
  or return malformed info are dropped. `timeout` bounds each `:erpc` call
  and defaults to 5_000 ms.
  """
  @spec list(node(), timeout()) :: {:ok, [table_info()]} | {:error, term()}
  def list(node, timeout \\ @default_timeout) do
    case Erpc.safe_call(node, :ets, :all, [], timeout) do
      {:ok, ids} when is_list(ids) -> fetch_infos(node, ids, timeout)
      {:ok, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns metadata for a single table on `node`.

  `table` is a name atom or a live `reference()` from a prior `list/2`.
  Returns `{:error, :not_found}` when `:ets.info/1` is `:undefined`.
  """
  @spec info(node(), TableId.t(), timeout()) :: {:ok, table_info()} | {:error, term()}
  def info(node, table, timeout \\ @default_timeout)

  def info(node, table, timeout) when is_atom(table) or is_reference(table) do
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
