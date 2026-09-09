defmodule Voyager.MCP.Tools.EtsList do
  @moduledoc """
  Lists ETS tables on the connected node, ranked by one attribute.

  Only metadata is read -- never table contents -- so payload size is bounded by
  `limit`. Private tables are included. `total` is the count of live tables before
  `search` and `limit`. `memory` is in bytes, `size` is row count.

  Pass the `id` string (never the `name`) to other ETS tools (`ets_read_table_chunk`,
  `ets_search_table`). Unnamed tables (`named_table: false`) can only be accessed
  via their `#Ref<...>` handle; referencing them by name fails.
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

    field :search, :string, description: "Case-insensitive filter on the table name or id."
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
      id_str =
        if is_reference(table.id) do
          table.id |> :erlang.ref_to_list() |> to_string()
        else
          Atom.to_string(table.id)
        end

      String.contains?(String.downcase(id_str), needle) or
        String.contains?(String.downcase(Atom.to_string(table.name)), needle)
    end)
  end

  defp sort_key(table, "name"), do: Atom.to_string(table.name)
  defp sort_key(table, "memory"), do: table.memory
  defp sort_key(table, "size"), do: table.size
end
