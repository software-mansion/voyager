defmodule Voyager.MCP.Tools.EtsList do
  @moduledoc """
  Lists the ETS tables of the connected node, ranked by one attribute.

  Only metadata is read -- never table contents -- so the payload is bounded by
  `limit` regardless of how much the tables hold. Private tables are included.
  `total` is the number of live tables found, before `search` and `limit`.
  `memory` is in bytes, `size` is the row count.

  `id` is the handle to pass to other ETS tools: a name for a named table, an
  unresolvable `#Ref<...>` for an unnamed one.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.Ets

  @sortable ~w(memory size name)

  schema do
    field :limit, :integer,
      default: 25,
      min: 1,
      max: 200,
      description: "How many tables to return."

    field :sort_by, :enum,
      values: @sortable,
      default: "memory",
      description: "Attribute to rank on."

    field :direction, :enum,
      values: ~w(desc asc),
      default: "desc",
      description: "`desc` ranks largest first, `asc` smallest first."

    field :search, :string,
      description: "Case-insensitive filter on the table name or id."
  end

  @impl true
  def execute(params, frame) do
    direction = if params.direction == "asc", do: :asc, else: :desc

    Remote.reply(
      &list(&1, params.sort_by, direction, params.limit, Map.get(params, :search)),
      frame
    )
  end

  defp list(node, sort_by, direction, limit, search) do
    with {:ok, tables} <- Ets.Remote.list(node) do
      ranked =
        tables
        |> filter(search)
        |> Enum.sort_by(&sort_key(&1, sort_by), direction)
        |> Enum.take(limit)

      {:ok, %{total: length(tables), tables: ranked}}
    end
  end

  defp filter(tables, search) when search in [nil, ""], do: tables

  defp filter(tables, search) do
    needle = String.downcase(search)

    Enum.filter(tables, fn table ->
      String.contains?(String.downcase(Ets.TableId.display(table.id)), needle) or
        String.contains?(String.downcase(Atom.to_string(table.name)), needle)
    end)
  end

  defp sort_key(table, "name"), do: Atom.to_string(table.name)
  defp sort_key(table, "memory"), do: table.memory
  defp sort_key(table, "size"), do: table.size
end
