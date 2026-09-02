defmodule Voyager.EtsFakes do
  @moduledoc """
  Canned ETS table metadata for tests: builds the parsed `table_info` maps the
  pages consume, and stubs `Voyager.ErpcMock` with the raw replies
  `Voyager.Services.Ets.Remote.list/2` fetches, so the real parsing runs over
  them.
  """

  import Mox

  @word_size 8

  @doc "The word size the canned node reports, in bytes."
  @spec word_size() :: pos_integer()
  def word_size, do: @word_size

  @doc """
  Builds a table as `Voyager.Services.Ets.Remote.list/2` would report it.
  `name` doubles as the `id` unless one is given, as it does for a named
  table. `memory` is in bytes and must be a multiple of the word size.
  """
  @spec table(keyword() | map()) :: VoyagerWeb.EtsTablesLive.Query.table()
  def table(overrides \\ []) do
    overrides = Map.new(overrides)
    name = Map.get(overrides, :name, :fake_table)

    table =
      Map.merge(
        %{
          id: name,
          name: name,
          named_table: true,
          protection: :public,
          type: :set,
          size: 0,
          memory: 0,
          owner: self(),
          heir: :none,
          keypos: 1,
          compressed: false,
          read_concurrency: false,
          write_concurrency: false
        },
        overrides
      )

    0 = rem(table.memory, @word_size)
    table
  end

  @doc """
  Stubs the remote calls behind `Remote.list/2`, `Remote.info/3` and
  `TableId.resolve/4` to report `tables`, sending `{:fetched, timeout}` to the
  calling test once per fetch (on `:ets.all/0` for a list, `:ets.info/1` for a
  single table).
  """
  @spec stub_list([map()]) :: :ok
  def stub_list(tables) do
    test = self()

    stub(Voyager.ErpcMock, :call, fn
      _node, :ets, :all, [], timeout ->
        send(test, {:fetched, timeout})
        ids(tables)

      _node, :ets, :info, [id], timeout ->
        send(test, {:fetched, timeout})

        case Enum.find(tables, &(&1.id == id)) do
          nil -> :undefined
          table -> raw_info(table)
        end

      _node, :erlang, :system_info, [:wordsize], _timeout ->
        @word_size

      _node, :erlang, :list_to_existing_atom, [chars], _timeout ->
        existing_atom(chars)

      _node, :lists, :map, [_fun, ids], _timeout ->
        raw_infos(tables, ids)
    end)

    :ok
  end

  # An unknown atom raises on the remote the way `:erpc` reports it.
  defp existing_atom(chars) do
    :erlang.list_to_existing_atom(chars)
  rescue
    ArgumentError -> :erlang.error({:exception, :badarg, []})
  end

  @doc "Stubs every remote call to fail the way `:erpc` reports `reason`."
  @spec stub_error(term()) :: :ok
  def stub_error(reason) do
    stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
      :erlang.error({:erpc, reason})
    end)

    :ok
  end

  @doc "The handles `:ets.all/0` would report for `tables`."
  @spec ids([map()]) :: [atom() | reference()]
  def ids(tables), do: Enum.map(tables, & &1.id)

  @doc """
  The raw `:ets.info/1` keyword lists for `ids`, as the remote `:lists.map`
  returns them; an id with no table is `:undefined`, as a table deleted
  mid-fetch would be.
  """
  @spec raw_infos([map()], [atom() | reference()]) :: [keyword() | :undefined]
  def raw_infos(tables, ids) do
    Enum.map(ids, fn id -> raw_info(Enum.find(tables, &(&1.id == id))) end)
  end

  defp raw_info(nil), do: :undefined

  defp raw_info(table) do
    info = [
      name: table.name,
      named_table: table.named_table,
      protection: table.protection,
      type: table.type,
      size: table.size,
      memory: div(table.memory, @word_size),
      owner: table.owner,
      heir: table.heir,
      keypos: table.keypos,
      compressed: table.compressed,
      read_concurrency: table.read_concurrency,
      write_concurrency: table.write_concurrency
    ]

    case table do
      %{decentralized_counters: value} -> info ++ [decentralized_counters: value]
      _table -> info
    end
  end
end
