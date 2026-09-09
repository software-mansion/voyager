defmodule Voyager.MCP.Tools.EtsSearchTable do
  @moduledoc """
  Searches an ETS table on the connected node using a raw match spec.

  `match_spec` is an Erlang term in source syntax, parsed by
  `Voyager.Services.Ets.MatchSpec.parse/1`. A single `{Head, Guards, Body}`
  clause is required — the same shape `:ets.fun2ms/1` produces. A missing
  trailing `.` is added automatically.

  Examples the LLM can send:

      [{{'$1', '$2'}, [{'>', '$2', 10}], ['$1']}]
      [{'$1', [], ['$_']}]

  Guard validity is checked by `:ets.select/3` on the target; an invalid guard
  comes back as `:cannot_read`.

  `cursor` is the opaque string returned in a previous response. To resume,
  re-send the same `table`, `match_spec`, `limit` and `budget` alongside it.

  Run `ets_list` first to discover table handles.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.MatchSpec
  alias Voyager.Services.Ets.TableId

  @default_budget Agent.default_budget()

  schema do
    field :table, :string,
      required: true,
      description: "Table name or id from `ets_list`."

    field :match_spec, :string,
      required: true,
      description:
        "Erlang match spec as a source term. One `{Head, Guards, Body}` clause. Example: `[{'$1', [], ['$_']}]`."

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
         {:ok, continuation} <- decode_cursor(Map.get(params, :cursor)) do
      Remote.reply(&fetch(&1, params, spec, continuation), frame)
    else
      {:error, {:invalid_match_spec, detail}} ->
        {:reply, Response.error(Response.tool(), "Invalid match spec: #{detail}"), frame}

      {:error, :invalid_cursor} ->
        {:reply, Response.error(Response.tool(), "Invalid cursor"), frame}
    end
  end

  defp parse_spec(string), do: MatchSpec.parse(string)

  defp fetch(node, params, spec, continuation) do
    with {:ok, tables} <- Ets.Remote.list(node),
         {:ok, table} <- TableId.resolve(node, params.table, tables, Agent.default_timeout()) do
      Fetch.select_spec(node, table, spec, params.limit, params.budget, continuation)
    end
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(string) do
    with {:ok, bin} <- Base.url_decode64(string) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :invalid_cursor}
  end
end

defmodule Voyager.MCP.Tools.EtsSearchTable do
  @moduledoc """
  Searches an ETS table on the connected node using a raw match spec.

  `match_spec` is an Erlang term in source syntax, parsed by
  `Voyager.Services.Ets.MatchSpec.parse/1`. A single `{Head, Guards, Body}`
  clause is required — the same shape `:ets.fun2ms/1` produces. A missing
  trailing `.` is added automatically.

  Examples the LLM can send:

      [{{'$1', '$2'}, [{'>', '$2', 10}], ['$1']}]
      [{'$1', [], ['$_']}]

  Guard validity is checked by `:ets.select/3` on the target; an invalid guard
  comes back as `:cannot_read`.

  `cursor` is the opaque string returned in a previous response. To resume,
  re-send the same `table`, `match_spec`, `limit` and `budget` alongside it.

  Run `ets_list` first to discover table handles.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.MatchSpec

  @default_budget Agent.default_budget()

  schema do
    field :table, :string,
      required: true,
      description: "Table name or id from `ets_list`."

    field :match_spec, :string,
      required: true,
      description:
        "Erlang match spec as a source term. One `{Head, Guards, Body}` clause. Example: `[{'$1', [], ['$_']}]`."

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
         {:ok, continuation} <- decode_cursor(Map.get(params, :cursor)) do
      Remote.reply(&fetch(&1, params, spec, continuation), frame)
    else
      {:error, {:invalid_match_spec, detail}} ->
        {:reply, Response.error(Response.tool(), "Invalid match spec: #{detail}"), frame}

      {:error, :invalid_cursor} ->
        {:reply, Response.error(Response.tool(), "Invalid cursor"), frame}
    end
  end

  defp parse_spec(string), do: MatchSpec.parse(string)

  defp fetch(node, params, spec, continuation) do
    case parse_table(params.table) do
      {:ok, table} ->
        Fetch.select_spec(node, table, spec, params.limit, params.budget, continuation)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_table("#Ref<" <> _ = ref_str) do
    {:ok, :erlang.list_to_ref(String.to_charlist(ref_str))}
  rescue
    ArgumentError -> {:error, :invalid_table_ref}
  end

  defp parse_table(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :invalid_table_name}
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(string) do
    with {:ok, bin} <- Base.url_decode64(string) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :invalid_cursor}
  end
end
