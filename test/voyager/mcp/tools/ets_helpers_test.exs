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
    test "encodes and decodes nil" do
      assert EtsHelpers.encode_cursor(nil) == nil
      assert EtsHelpers.decode_cursor(nil) == {:ok, nil}
    end

    test "round-trips an arbitrary term" do
      term = {:cont, 123, "marker"}
      encoded = EtsHelpers.encode_cursor(term)
      assert is_binary(encoded)
      assert EtsHelpers.decode_cursor(encoded) == {:ok, term}
    end

    test "returns error for a malformed cursor" do
      assert EtsHelpers.decode_cursor("not-base64!") == {:error, :invalid_cursor}
    end

    test "rejects an unsigned term cursor without decoding it" do
      forged = Base.url_encode64(:erlang.term_to_binary({:cont, 123}))
      assert EtsHelpers.decode_cursor(forged) == {:error, :invalid_cursor}
    end

    test "rejects an oversized cursor" do
      assert EtsHelpers.decode_cursor(String.duplicate("a", 17_000)) ==
               {:error, :invalid_cursor}
    end
  end

  describe "format_chunk/1" do
    test "replaces :continuation with :cursor" do
      cont = {:next, 1}
      chunk = %{records: [1, 2], continuation: cont, truncated?: false}

      assert {:ok, formatted} = EtsHelpers.format_chunk({:ok, chunk})
      refute Map.has_key?(formatted, :continuation)
      assert formatted.cursor == EtsHelpers.encode_cursor(cont)
      assert formatted.records == [1, 2]
    end

    test "sets cursor to nil when continuation is nil" do
      chunk = %{records: [1, 2], continuation: nil}

      assert {:ok, formatted} = EtsHelpers.format_chunk({:ok, chunk})
      assert formatted.cursor == nil
    end

    test "passes through errors" do
      assert EtsHelpers.format_chunk({:error, :some_error}) == {:error, :some_error}
    end
  end
end
