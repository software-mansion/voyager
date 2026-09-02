defmodule VoyagerWeb.EtsTablesLive.QueryTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.EtsFakes
  alias VoyagerWeb.EtsTablesLive.Query

  @node :"peer@127.0.0.1"

  defp names(tables), do: Enum.map(tables, & &1.name)

  describe "all/2" do
    test "returns every table with the fetch time, passing the timeout through" do
      tables = [EtsFakes.table(name: :a), EtsFakes.table(name: :b)]
      EtsFakes.stub_list(tables)

      assert {:ok, page} = Query.all(@node, 3_000)
      assert page.entries == tables
      assert %DateTime{} = page.fetched_at
      assert_received {:fetched, 3_000}
    end

    test "drops a table deleted between the listing and its info" do
      tables = [EtsFakes.table(name: :a)]

      stub(Voyager.ErpcMock, :call, fn
        _node, :ets, :all, [], _timeout -> [:a, :gone]
        _node, :erlang, :system_info, [:wordsize], _timeout -> EtsFakes.word_size()
        _node, :lists, :map, [_fun, ids], _timeout -> EtsFakes.raw_infos(tables, ids)
      end)

      assert {:ok, %{entries: [%{name: :a}]}} = Query.all(@node, 1_000)
    end

    test "propagates transport errors" do
      EtsFakes.stub_error(:noconnection)

      assert {:error, :noconnection} = Query.all(@node, 1_000)
    end
  end

  describe "get/3" do
    test "resolves a named table by its bare name and its inspect string" do
      EtsFakes.stub_list([EtsFakes.table(name: :my_table), EtsFakes.table(name: :other)])

      assert {:ok, %{name: :my_table}} = Query.get(@node, "my_table", 1_000)
      assert {:ok, %{name: :my_table}} = Query.get(@node, ":my_table", 1_000)
    end

    test "resolves an unnamed table only by its live reference" do
      ref = make_ref()

      EtsFakes.stub_list([
        EtsFakes.table(name: :scratch, id: ref, named_table: false, protection: :private)
      ])

      assert {:ok, %{id: ^ref}} = Query.get(@node, inspect(ref), 1_000)
      assert {:error, :not_found} = Query.get(@node, inspect(make_ref()), 1_000)
    end

    test "reports a table the node does not have" do
      EtsFakes.stub_list([EtsFakes.table(name: :present)])

      assert {:error, :not_found} = Query.get(@node, "missing", 1_000)
    end

    test "propagates transport errors" do
      EtsFakes.stub_error(:timeout)

      assert {:error, :timeout} = Query.get(@node, "my_table", 1_000)
    end
  end

  describe "sort/3" do
    test "defaults to memory, largest first" do
      assert Query.default_sort() == {:memory, :desc}

      tables = [
        EtsFakes.table(name: :small, memory: 8),
        EtsFakes.table(name: :large, memory: 800),
        EtsFakes.table(name: :mid, memory: 80)
      ]

      assert names(Query.sort(tables, :memory, :desc)) == [:large, :mid, :small]
      assert names(Query.sort(tables, :memory, :asc)) == [:small, :mid, :large]
    end

    test "sorts names case-insensitively on their display form" do
      tables = [
        EtsFakes.table(name: :zeta),
        EtsFakes.table(name: :Alpha),
        EtsFakes.table(name: :beta)
      ]

      assert names(Query.sort(tables, :name, :asc)) == [:Alpha, :beta, :zeta]
      assert names(Query.sort(tables, :name, :desc)) == [:zeta, :beta, :Alpha]
    end

    test "sorts by object count and owner" do
      [older, newer] = Enum.map(1..2, fn _ -> spawn(fn -> :ok end) end)

      tables = [
        EtsFakes.table(name: :a, size: 20, owner: newer),
        EtsFakes.table(name: :b, size: 10, owner: older)
      ]

      assert names(Query.sort(tables, :size, :asc)) == [:b, :a]
      assert names(Query.sort(tables, :owner, :asc)) == [:b, :a]
    end

    test "breaks ties on the name so equal values keep a stable order" do
      tables = [
        EtsFakes.table(name: :b, memory: 8),
        EtsFakes.table(name: :a, memory: 8),
        EtsFakes.table(name: :c, memory: 8)
      ]

      assert names(Query.sort(tables, :memory, :asc)) == [:a, :b, :c]
      assert names(Query.sort(tables, :memory, :desc)) == [:c, :b, :a]
    end

    test "every sortable column is a table field or the name" do
      table = EtsFakes.table()

      for attr <- Query.sortable_attrs() do
        assert Map.has_key?(table, attr)
      end
    end
  end

  describe "filter/2" do
    test "keeps everything for a blank search" do
      tables = [EtsFakes.table(name: :a), EtsFakes.table(name: :b)]

      assert Query.filter(tables, "") == tables
      assert Query.filter(tables, nil) == tables
    end

    test "matches the name case-insensitively" do
      tables = [EtsFakes.table(name: MyApp.Cache), EtsFakes.table(name: :ac_tab)]

      assert names(Query.filter(tables, "cache")) == [MyApp.Cache]
      assert names(Query.filter(tables, "AC_")) == [:ac_tab]
    end

    test "matches an unnamed table by its reference" do
      ref = make_ref()

      tables = [
        EtsFakes.table(name: :scratch, id: ref, named_table: false),
        EtsFakes.table(name: :other)
      ]

      assert names(Query.filter(tables, inspect(ref))) == [:scratch]
    end

    test "matches the owner, the type and the protection" do
      owner = spawn(fn -> :ok end)

      tables = [
        EtsFakes.table(name: :a, owner: owner, type: :duplicate_bag, protection: :private),
        EtsFakes.table(name: :b, type: :set)
      ]

      assert names(Query.filter(tables, VoyagerWeb.Formatters.format_pid(owner))) == [:a]
      assert names(Query.filter(tables, "duplicate")) == [:a]
      assert names(Query.filter(tables, "private")) == [:a]
    end
  end

  describe "total_memory/1" do
    test "sums the bytes of every table" do
      tables = [EtsFakes.table(memory: 8), EtsFakes.table(memory: 16)]

      assert Query.total_memory(tables) == 24
      assert Query.total_memory([]) == 0
    end
  end
end
