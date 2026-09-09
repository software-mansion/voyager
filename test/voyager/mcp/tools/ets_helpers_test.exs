defmodule Voyager.MCP.Tools.EtsHelpersTest do
  use ExUnit.Case, async: true

  alias Voyager.MCP.Tools.EtsHelpers

  describe "parse_table/1" do
    test "parses an existing atom" do
      assert EtsHelpers.parse_table("code") == {:ok, :code}
    end

    test "returns :invalid_table_name for non-existent atom" do
      assert EtsHelpers.parse_table("non_existent_atom_definitely_not_defined_xyz123") ==
               {:error, :invalid_table_name}
    end

    test "parses a reference string" do
      ref = make_ref()
      ref_str = inspect(ref)
      assert EtsHelpers.parse_table(ref_str) == {:ok, ref}
    end

    test "returns :invalid_table_ref for malformed reference" do
      assert EtsHelpers.parse_table("#Ref<invalid>") == {:error, :invalid_table_ref}
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

    test "returns error for invalid base64 cursor" do
      assert EtsHelpers.decode_cursor("not-base64!") == {:error, :invalid_cursor}
    end

    test "returns error for base64 that does not decode to a valid safe term" do
      # base64 of invalid term bytes
      assert EtsHelpers.decode_cursor(Base.url_encode64("random bytes")) ==
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
