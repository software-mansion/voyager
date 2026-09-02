defmodule VoyagerWeb.EtsTablesLive.Query do
  @moduledoc """
  Loads the ETS table list: wraps `Voyager.Services.Ets.Remote` with the shape
  the pages need, and owns the search and the sort, which work on the last
  fetch and never cost a remote call.

  A table handle is its name atom or, for an unnamed table, the live
  `reference()` the node reported; `Voyager.Services.Ets.TableId` carries one
  through a URL and back.
  """

  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Formatters

  @sortable ~w(name size memory owner)a
  @default_sort {:memory, :desc}

  # `name` identifies the row and `memory` is the default ranking, so neither
  # can be turned off.
  @required_attrs ~w(name memory)a
  @optional_attrs ~w(protection type size owner named_table keypos heir compressed read_concurrency write_concurrency decentralized_counters)a
  @default_attrs ~w(protection type size owner)a

  @type table :: Remote.table_info()
  @type direction :: :asc | :desc
  @type sort :: {atom(), direction()}
  @type page :: %{entries: [table()], fetched_at: DateTime.t()}

  @spec default_sort() :: sort()
  def default_sort, do: @default_sort

  @doc "Columns the list can be sorted on. Protection and type are categories, so they are picked instead."
  @spec sortable_attrs() :: [atom()]
  def sortable_attrs, do: @sortable

  @spec required_attrs() :: [atom()]
  def required_attrs, do: @required_attrs

  @spec optional_attrs() :: [atom()]
  def optional_attrs, do: @optional_attrs

  @spec default_attrs() :: [atom()]
  def default_attrs, do: @default_attrs

  @doc "Fetches the metadata of every ETS table on `node`, bounding each remote call by `timeout`."
  @spec all(node(), timeout()) :: {:ok, page()} | {:error, term()}
  def all(node, timeout) do
    with {:ok, tables} <- Remote.list(node, timeout) do
      {:ok, %{entries: tables, fetched_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Fetches the metadata of the table `string` names.

  A name is interned on the node and fetched alone; a reference is only
  meaningful in a fresh list of the node's tables, so it is found there.
  """
  @spec get(node(), String.t(), timeout()) :: {:ok, table()} | {:error, :not_found | term()}
  def get(node, "#Ref" <> _ = string, timeout) do
    with {:ok, %{entries: tables}} <- all(node, timeout) do
      case find(tables, string) do
        {:ok, table} -> {:ok, table}
        :error -> {:error, :not_found}
      end
    end
  end

  def get(node, string, timeout) when is_binary(string) do
    case TableId.resolve(node, string, [], timeout) do
      {:ok, id} -> Remote.info(node, id, timeout)
      {:error, :invalid_name} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Finds the table `string` names among `tables`, by name or inspect-string."
  @spec find([table()], String.t()) :: {:ok, table()} | :error
  def find(tables, string) when is_binary(string) do
    case Enum.find(tables, &TableId.matches?(string, &1.id)) do
      nil -> :error
      table -> {:ok, table}
    end
  end

  @doc """
  Keeps the tables whose name, id, type, protection or owner contains
  `search`, case-insensitively. A blank search keeps everything.
  """
  @spec filter([table()], String.t() | nil) :: [table()]
  def filter(tables, search) when search in [nil, ""], do: tables

  def filter(tables, search) when is_binary(search) do
    needle = String.downcase(search)

    Enum.filter(tables, &String.contains?(haystack(&1), needle))
  end

  @doc """
  Sorts by one of `sortable_attrs/0`, breaking ties on the table name so equal
  values keep a stable order between refreshes.
  """
  @spec sort([table()], atom(), direction()) :: [table()]
  def sort(tables, sort_by, direction)
      when sort_by in @sortable and direction in [:asc, :desc] do
    Enum.sort_by(tables, &{sort_key(&1, sort_by), name_key(&1)}, direction)
  end

  @doc "Bytes held by `tables` together."
  @spec total_memory([table()]) :: non_neg_integer()
  def total_memory(tables), do: Enum.sum_by(tables, & &1.memory)

  defp haystack(table) do
    [
      inspect(table.name),
      TableId.display(table.id),
      Formatters.format_pid(table.owner),
      table.type,
      table.protection
    ]
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp sort_key(table, :name), do: name_key(table)
  defp sort_key(table, key), do: Map.get(table, key)

  defp name_key(table), do: table.name |> inspect() |> String.downcase()
end
