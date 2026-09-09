defmodule Voyager.MCP.Tools.EtsSearchTable do
  @moduledoc """
  Searches an ETS table on the connected node using an Erlang match specification.

  Use this when queries require multi-element patterns, guards, or conditions
  beyond `ets_read_table_chunk`'s basic modes.

  Pass the `id` string from `ets_list` into `table` (pass `#Ref<...>` for unnamed tables).

  `match_spec` rules:
  - Must be a valid Erlang term string with one `[{Head, Guards, Body}]` clause.
  - Match variables must be single-quoted atoms: `'$1'`, `'$2'`, `'_'`, `'$_'`.
  - Guards only support Erlang guard BIFs (e.g. `=:=`, `>`, `<`, `is_list`, `is_binary`,
    `element`, `binary_part`, `byte_size`). Calling other functions fails with `:cannot_read`.
  - OTP strings (such as paths in `code_server` tables) are Erlang charlists (list of integers).
    To match a charlist prefix, use a list pattern like `[47, 104, 111 | '$rest']`.

  Examples:
  - Match all: `[{'$1', [], ['$_']}]`
  - Guard comparison: `[{{'$1', '$2'}, [{'>', '$2', 10}], ['$1']}]`
  - Element match: `[{{'$1', active, '$3'}, [], ['$_']}]`

  `cursor` is the opaque string returned in a previous response. To resume,
  re-send the same `table`, `match_spec`, `limit` and `budget` alongside it.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.MCP.Tools.EtsHelpers
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.MatchSpec

  @default_budget Agent.default_budget()

  schema do
    field :table, :string,
      required: true,
      description:
        "Table handle from `ets_list` `id`. Pass `#Ref<...>` for unnamed tables, never the name."

    field :match_spec, :string,
      required: true,
      description:
        "Erlang match spec term with one [{Head, Guards, Body}] clause. Match variables must be quoted like '$1' or '$_'."

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
    with {:ok, spec} <- parse_spec(params.match_spec),
         {:ok, continuation} <- EtsHelpers.decode_cursor(Map.get(params, :cursor)) do
      Remote.reply(&fetch(&1, params, spec, continuation), frame)
    else
      {:error, {:invalid_match_spec, detail}} ->
        {:reply, Response.error(Response.tool(), "Invalid match spec: #{detail}"), frame}

      {:error, :invalid_cursor} ->
        {:reply, Response.error(Response.tool(), "Invalid cursor format provided"), frame}
    end
  end

  defp parse_spec(string), do: MatchSpec.parse(string)

  defp fetch(node, params, spec, continuation) do
    case EtsHelpers.parse_table(params.table) do
      {:ok, table} ->
        Fetch.select_spec(node, table, spec, params.limit, params.budget, continuation)
        |> EtsHelpers.format_chunk()

      {:error, reason} ->
        {:error, reason}
    end
  end
end
