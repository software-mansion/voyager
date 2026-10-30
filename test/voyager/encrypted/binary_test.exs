defmodule Voyager.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias Voyager.Encrypted.Binary

  @cloak_ciphertext Base.decode64!(
                      "AQpBRVMuR0NNLlYxNJ4NtPc/OFT+2n08guR956qz3B6NNFw1B1Mv07iVBfZ4uqit1p3q+g93+hL4"
                    )

  @header_size 12
  @iv_size 16
  @tag_size 16

  for {region, offset} <- [
        iv: @header_size,
        tag: @header_size + @iv_size,
        ciphertext: @header_size + @iv_size + @tag_size
      ] do
    test "rejects a value with a tampered #{region}" do
      assert Binary.load(flip_bit(@cloak_ciphertext, unquote(offset))) == :error
    end
  end

  test "rejects a truncated value" do
    truncated = binary_part(@cloak_ciphertext, 0, byte_size(@cloak_ciphertext) - 1)
    assert Binary.load(truncated) == :error
  end

  test "rejects an unknown header" do
    assert Binary.load(flip_bit(@cloak_ciphertext, 2)) == :error
  end

  test "loads a value written by Cloak" do
    assert Binary.load(@cloak_ciphertext) == {:ok, "secret_cookie"}
  end

  defp flip_bit(value, offset) do
    <<prefix::binary-size(^offset), byte, rest::binary>> = value
    <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end
end
