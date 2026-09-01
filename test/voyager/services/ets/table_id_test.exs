defmodule Voyager.Services.Ets.TableIdTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Services.Ets.TableId

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"
  @timeout 1_000

  describe "display/1" do
    test "uses inspect/1 for atoms and references" do
      ref = make_ref()
      assert TableId.display(:my_table) == inspect(:my_table)
      assert TableId.display(ref) == inspect(ref)
    end

    test "uses the alias inspect-form for module-named tables" do
      assert TableId.display(MyApp.Cache) == "MyApp.Cache"
    end
  end

  describe "find/2" do
    test "matches a named table by inspect and by Atom.to_string/1" do
      ids = [:my_table, make_ref()]

      assert {:ok, :my_table} = TableId.find(inspect(:my_table), ids)
      assert {:ok, :my_table} = TableId.find("my_table", ids)
    end

    test "matches a module-named table by alias inspect-form and Atom.to_string/1" do
      ids = [MyApp.Cache]

      assert {:ok, MyApp.Cache} = TableId.find("MyApp.Cache", ids)
      assert {:ok, MyApp.Cache} = TableId.find("Elixir.MyApp.Cache", ids)
    end

    test "matches an unnamed table only by inspect of the live reference" do
      ref = make_ref()
      assert {:ok, ^ref} = TableId.find(inspect(ref), [ref, :other])
    end

    test "matches :id on table_info maps from Remote" do
      ref = make_ref()
      tables = [%{id: :named, name: :named}, %{id: ref, name: :unnamed}]

      assert {:ok, :named} = TableId.find("named", tables)
      assert {:ok, ^ref} = TableId.find(inspect(ref), tables)
    end

    test "returns :error when nothing matches" do
      assert :error = TableId.find(inspect(make_ref()), [:my_table])
      assert :error = TableId.find("missing", [])
    end
  end

  describe "resolve/4" do
    test "prefers the last all() over a remote atom lookup" do
      assert {:ok, :my_table} = TableId.resolve(@node, "my_table", [:my_table], @timeout)
    end

    test "does not reconstruct a reference inspect-string missing from last all" do
      string = inspect(make_ref())
      assert {:error, :not_found} = TableId.resolve(@node, string, [], @timeout)
    end

    test "does not reconstruct the Erlang #Ref inspect form" do
      assert {:error, :not_found} = TableId.resolve(@node, "#Ref<0.1.2.3>", [], @timeout)
    end

    test "interns a typed name on the target when last all misses" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"cache"],
                                         @timeout ->
        :cache
      end)

      assert {:ok, :cache} = TableId.resolve(@node, "cache", [], @timeout)
    end

    test "interns a module alias inspect-form on the target when last all misses" do
      expect(Voyager.ErpcMock, :call, fn @node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"Elixir.MyApp.Cache"],
                                         @timeout ->
        MyApp.Cache
      end)

      assert {:ok, MyApp.Cache} = TableId.resolve(@node, "MyApp.Cache", [], @timeout)
    end
  end

  describe "existing_atom/3" do
    test "calls list_to_existing_atom on the target with a charlist and timeout" do
      test = self()

      expect(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
        send(test, {:called, node, mod, fun, args, timeout})
        :foo
      end)

      assert {:ok, :foo} = TableId.existing_atom(@node, "foo", @timeout)

      assert_received {:called, @node, :erlang, :list_to_existing_atom, [~c"foo"], @timeout}
    end

    test "strips a leading Elixir colon from inspect-form names" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"bar"],
                                         _timeout ->
        :bar
      end)

      assert {:ok, :bar} = TableId.existing_atom(@node, ":bar", @timeout)
    end

    test "prepends Elixir. for alias inspect-forms" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"Elixir.MyApp.Cache"],
                                         _timeout ->
        MyApp.Cache
      end)

      assert {:ok, MyApp.Cache} = TableId.existing_atom(@node, "MyApp.Cache", @timeout)
    end

    test "does not double-prefix Atom.to_string/1 module names" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"Elixir.MyApp.Cache"],
                                         _timeout ->
        MyApp.Cache
      end)

      assert {:ok, MyApp.Cache} = TableId.existing_atom(@node, "Elixir.MyApp.Cache", @timeout)
    end

    test "does not prepend Elixir. after stripping a quoted uppercase inspect-form" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [~c"MyApp.Cache"],
                                         _timeout ->
        :"MyApp.Cache"
      end)

      assert {:ok, :"MyApp.Cache"} = TableId.existing_atom(@node, ":MyApp.Cache", @timeout)
    end

    test "rejects a blank name without touching the remote" do
      assert {:error, :invalid_name} = TableId.existing_atom(@node, "  ", @timeout)
      assert {:error, :invalid_name} = TableId.existing_atom(@node, ":", @timeout)
    end

    test "rejects a name longer than 255 characters without touching the remote" do
      assert {:error, :invalid_name} =
               TableId.existing_atom(@node, String.duplicate("a", 256), @timeout)
    end

    test "interns a 255-character name on the target" do
      name = String.duplicate("a", 255)
      chars = String.to_charlist(name)

      expect(Voyager.ErpcMock, :call, fn @node,
                                         :erlang,
                                         :list_to_existing_atom,
                                         [^chars],
                                         @timeout ->
        :t
      end)

      assert {:ok, :t} = TableId.existing_atom(@node, name, @timeout)
    end

    test "rejects an alias whose Elixir. form exceeds 255 characters without touching the remote" do
      name = "A" <> String.duplicate("x", 248)

      assert {:error, :invalid_name} = TableId.existing_atom(@node, name, @timeout)
    end

    test "maps a remote badarg to :not_found" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert {:error, :not_found} = TableId.existing_atom(@node, "no_such_atom", @timeout)
    end

    test "returns :invalid_response when the target does not return an atom" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> "not-an-atom" end)

      assert {:error, :invalid_response} = TableId.existing_atom(@node, "foo", @timeout)
    end

    test "propagates transport errors" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = TableId.existing_atom(@node, "foo", @timeout)
    end
  end
end
