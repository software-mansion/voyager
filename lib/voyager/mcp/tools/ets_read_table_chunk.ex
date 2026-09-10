defmodule Voyager.MCP.Tools.EtsReadTableChunk do
  @moduledoc """
  Reads or paginates through an ETS table on the connected node.

  Pass the `id` value from `ets_list` into `table`. For unnamed tables (`named_table: false`),
  pass the full `#Reference<...>` reference string; passing the table name fails.

  Filter modes via `Voyager.Services.Ets.Search.chunk/8`:
  - Omit `mode` entirely for an unfiltered scan.
  - `key_eq` — rows whose key equals `value` (single-shot, no paging).
  - `key_prefix` — rows whose binary key starts with `value`.
  - `element_eq` — rows whose tuple element at 1-based `index` equals `value`.
  Substring search is not supported here; use `ets_search_table` for raw match specs.

  `value` is parsed as an integer when fully numeric, as an atom when prefixed
  with `:` (interned on target via `:erlang.list_to_existing_atom/1`), or kept as binary.

  `cursor` is the opaque string returned in a previous response. To resume,
  re-send it with the same `table` and filter parameters — a cursor issued for
  a different query is rejected.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.Erpc
  alias Voyager.MCP.Tools.EtsHelpers
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Search
  alias Voyager.Services.Ets.TableId

  @default_budget Agent.default_budget()
  @modes ~w(key_eq key_prefix element_eq)

  schema do
    field :table, :string,
      required: true,
      description:
        "Table handle from `ets_list` `id`. Pass `#Reference<...>` for unnamed tables, never the name."

    field :mode, :enum,
      values: @modes,
      description:
        "Filter mode: `key_eq`, `key_prefix`, or `element_eq`. Omit for unfiltered scan. For match specs, use `ets_search_table`."

    field :value, :string,
      description:
        "Filter value. Required when `mode` is set. Prefix with `:` for an atom, otherwise parsed as integer if numeric, binary otherwise."

    field :index, :integer,
      min: 1,
      description: "Tuple element position (1-based). Required for `element_eq`."

    field :keypos, :integer,
      required: true,
      min: 1,
      description: "Key position of the table, as reported by `ets_list`."

    field :limit, :integer,
      default: 25,
      min: 1,
      max: 500,
      description: "Maximum rows per page."

    field :budget, :integer,
      default: @default_budget,
      min: 100,
      description: "Term size cap per record."

    field :cursor, :string, description: "Opaque continuation from a previous response."
  end

  @impl true
  def execute(params, frame) do
    with :ok <- validate(params),
         {:ok, continuation} <- EtsHelpers.decode_cursor(Map.get(params, :cursor), scope(params)) do
      Remote.reply(&fetch(&1, params, continuation), frame)
    else
      {:error, :cursor_mismatch} ->
        {:reply, Response.error(Response.tool(), "Cursor does not match the query parameters"),
         frame}

      {:error, :invalid_cursor} ->
        {:reply, Response.error(Response.tool(), "Invalid cursor format provided"), frame}

      {:error, message} ->
        {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  defp validate(%{mode: "element_eq"} = params) do
    cond do
      not is_integer(Map.get(params, :index)) -> {:error, "`index` is required for element_eq"}
      blank_value?(params) -> {:error, "`value` is required when `mode` is set"}
      true -> :ok
    end
  end

  defp validate(%{mode: "key_prefix"} = params) do
    if is_binary(Map.get(params, :value)),
      do: :ok,
      else: {:error, "`value` is required for key_prefix"}
  end

  defp validate(%{mode: "key_eq"} = params) do
    if blank_value?(params), do: {:error, "`value` is required when `mode` is set"}, else: :ok
  end

  defp validate(_params), do: :ok

  defp blank_value?(params), do: Map.get(params, :value) in [nil, ""]

  defp scope(params) do
    {params.table, Map.get(params, :mode), Map.get(params, :value), Map.get(params, :index),
     params.keypos}
  end

  defp fetch(node, params, continuation) do
    with {:ok, query} <- build_query(node, params),
         {:ok, table} <- EtsHelpers.parse_table(node, params.table) do
      case query do
        nil ->
          Fetch.select_chunk(node, table, params.limit, params.budget, continuation)

        query ->
          Search.chunk(
            node,
            table,
            query,
            params.keypos,
            params.limit,
            params.budget,
            continuation
          )
      end
      |> EtsHelpers.format_chunk(scope(params))
    end
  end

  defp build_query(node, %{mode: "key_eq"} = params) do
    with {:ok, scalar} <- cast_scalar(node, params.value) do
      {:ok, {:key_eq, scalar}}
    end
  end

  defp build_query(_node, %{mode: "key_prefix", value: ""}), do: {:ok, nil}

  defp build_query(_node, %{mode: "key_prefix", value: val}), do: {:ok, {:key_prefix, val}}

  defp build_query(node, %{mode: "element_eq", index: index} = params) do
    with {:ok, scalar} <- cast_scalar(node, params.value) do
      {:ok, {:element_eq, index, scalar}}
    end
  end

  defp build_query(_node, _params), do: {:ok, nil}

  defp cast_scalar(node, ":" <> _ = val) do
    case TableId.existing_atom(node, val, Erpc.default_timeout()) do
      {:ok, atom} -> {:ok, atom}
      {:error, e} when e in [:not_found, :invalid_name] -> {:error, :unknown_atom_value}
      {:error, _} = err -> err
    end
  end

  defp cast_scalar(_node, val) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _other -> {:ok, val}
    end
  end
end
