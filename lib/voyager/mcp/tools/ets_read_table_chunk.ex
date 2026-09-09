defmodule Voyager.MCP.Tools.EtsReadTableChunk do
  @moduledoc """
  Reads or paginates through an ETS table on the connected node.

  Pass the `id` value from `ets_list` into `table`. For unnamed tables (`named_table: false`),
  pass the full `#Ref<...>` reference string; passing the table name fails.

  Filter modes via `Voyager.Services.Ets.Search.chunk/8`:
  - Omit `mode` entirely for an unfiltered scan.
  - `key_eq` — rows whose key equals `value` (single-shot, no paging).
  - `key_prefix` — rows whose binary key starts with `value`.
  - `element_eq` — rows whose tuple element at 1-based `index` equals `value`.
  Substring search is not supported here; use `ets_search_table` for raw match specs.

  `value` is parsed as an integer when fully numeric, as an atom when prefixed
  with `:` (interned on target via `:erlang.list_to_existing_atom/1`), or kept as binary.

  `cursor` is the opaque string returned in a previous response. To resume,
  re-send the same parameters alongside it — a mismatch produces `:cannot_read`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.MCP.Tools.EtsHelpers
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Search

  @default_budget Agent.default_budget()
  @modes ~w(key_eq key_prefix element_eq)

  schema do
    field :table, :string,
      required: true,
      description:
        "Table handle from `ets_list` `id`. Pass `#Ref<...>` for unnamed tables, never the name."

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
      default: 1,
      min: 1,
      description: "Key position of the table from `ets_list`."

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
    case EtsHelpers.decode_cursor(Map.get(params, :cursor)) do
      {:ok, continuation} ->
        case build_query(params) do
          {:ok, query} ->
            Remote.reply(&fetch(&1, params, query, continuation), frame)

          {:error, reason} ->
            {:reply, Response.error(Response.tool(), reason), frame}
        end

      {:error, :invalid_cursor} ->
        {:reply, Response.error(Response.tool(), "Invalid cursor format provided"), frame}
    end
  end

  defp fetch(node, params, nil, continuation) do
    case EtsHelpers.parse_table(params.table) do
      {:ok, table} ->
        Fetch.select_chunk(node, table, params.limit, params.budget, continuation)
        |> EtsHelpers.format_chunk()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(node, params, query, continuation) do
    case EtsHelpers.parse_table(params.table) do
      {:ok, table} ->
        Search.chunk(node, table, query, params.keypos, params.limit, params.budget, continuation)
        |> EtsHelpers.format_chunk()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_query(%{mode: "key_eq"} = params) do
    with {:ok, scalar} <- parse_scalar(params) do
      {:ok, {:key_eq, scalar}}
    end
  end

  defp build_query(%{mode: "key_prefix", value: ""}), do: {:ok, nil}

  defp build_query(%{mode: "key_prefix", value: val}) when is_binary(val) do
    {:ok, {:key_prefix, val}}
  end

  defp build_query(%{mode: "key_prefix"}), do: {:error, "`value` is required for key_prefix"}

  defp build_query(%{mode: "element_eq", index: index} = params) when is_integer(index) do
    with {:ok, scalar} <- parse_scalar(params) do
      {:ok, {:element_eq, index, scalar}}
    end
  end

  defp build_query(%{mode: "element_eq"}), do: {:error, "`index` is required for element_eq"}

  defp build_query(_params), do: {:ok, nil}

  defp parse_scalar(%{value: val}) when is_binary(val) and val != "", do: {:ok, cast_scalar(val)}
  defp parse_scalar(_params), do: {:error, "`value` is required when `mode` is set"}

  defp cast_scalar(":" <> rest), do: String.to_existing_atom(rest)

  defp cast_scalar(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _other -> val
    end
  end
end
