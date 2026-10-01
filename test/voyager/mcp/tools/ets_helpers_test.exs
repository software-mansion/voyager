defmodule Voyager.MCP.Tools.EtsHelpersTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.MCP.Tools.EtsHelpers

  setup :verify_on_exit!

  @node :fake@localhost

  describe "parse_table/2" do
    test "resolves a name on the target" do
      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :list_to_existing_atom, [~c"code"], _t ->
        :code
      end)

      assert EtsHelpers.parse_table(@node, "code") == {:ok, :code}
    end

    test "returns :invalid_table_name when the atom is not interned on the target" do
      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :list_to_existing_atom, _args, _t ->
        :erlang.error({:exception, :badarg, []})
      end)

      assert EtsHelpers.parse_table(@node, "no_such_table") == {:error, :invalid_table_name}
    end

    test "parses an Elixir reference string" do
      ref = make_ref()
      assert EtsHelpers.parse_table(@node, inspect(ref)) == {:ok, ref}
    end

    test "parses an Erlang reference string" do
      ref = make_ref()
      ref_str = ref |> :erlang.ref_to_list() |> to_string()
      assert EtsHelpers.parse_table(@node, ref_str) == {:ok, ref}
    end

    test "returns :invalid_table_ref for malformed reference" do
      assert EtsHelpers.parse_table(@node, "#Ref<invalid>") == {:error, :invalid_table_ref}
    end
  end

  describe "cursor encoding and decoding" do
    @scope {"my_table", "query"}

    test "encodes and decodes nil" do
      assert EtsHelpers.encode_cursor(nil, @scope) == nil
      assert EtsHelpers.decode_cursor(nil, @scope) == {:ok, nil}
    end

    test "round-trips an arbitrary term under the same scope" do
      term = {:cont, 123, "marker"}
      encoded = EtsHelpers.encode_cursor(term, @scope)
      assert is_binary(encoded)
      assert EtsHelpers.decode_cursor(encoded, @scope) == {:ok, term}
    end

    test "rejects a cursor under a different scope" do
      encoded = EtsHelpers.encode_cursor({:cont, 123}, @scope)

      assert EtsHelpers.decode_cursor(encoded, {"other_table", "query"}) ==
               {:error, :cursor_mismatch}
    end

    test "returns error for a malformed cursor" do
      assert EtsHelpers.decode_cursor("not-base64!", @scope) == {:error, :invalid_cursor}
    end

    test "rejects an unsigned term cursor without decoding it" do
      forged = Base.url_encode64(:erlang.term_to_binary({@scope, {:cont, 123}}))
      assert EtsHelpers.decode_cursor(forged, @scope) == {:error, :invalid_cursor}
    end

    test "rejects an oversized cursor" do
      assert EtsHelpers.decode_cursor(String.duplicate("a", 17_000), @scope) ==
               {:error, :invalid_cursor}
    end
  end

  describe "format_chunk/2" do
    test "replaces :continuation with a scoped :cursor" do
      cont = {:next, 1}
      chunk = %{records: [1, 2], continuation: cont, truncated?: false}

      assert {:ok, formatted} = EtsHelpers.format_chunk({:ok, chunk}, @scope)
      refute Map.has_key?(formatted, :continuation)
      assert EtsHelpers.decode_cursor(formatted.cursor, @scope) == {:ok, cont}
      assert formatted.records == [1, 2]
    end

    test "sets cursor to nil when continuation is nil" do
      chunk = %{records: [1, 2], continuation: nil}

      assert {:ok, formatted} = EtsHelpers.format_chunk({:ok, chunk}, @scope)
      assert formatted.cursor == nil
    end

    test "passes through errors" do
      assert EtsHelpers.format_chunk({:error, :some_error}, @scope) == {:error, :some_error}
    end
  end
end
