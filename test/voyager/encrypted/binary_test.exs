defmodule Voyager.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias Voyager.Encrypted.Binary

  @cloak_ciphertext Base.decode64!(
                      "AQpBRVMuR0NNLlYxNJ4NtPc/OFT+2n08guR956qz3B6NNFw1B1Mv07iVBfZ4uqit1p3q+g93+hL4"
                    )

  @other_key_ciphertext Base.decode64!(
                          "AQpBRVMuR0NNLlYxJwdV9kEk66LvQixtRLdrgLL0CDrm9h0RazYjUIM902WRIFvnyxztAdQFuG1w"
                        )

  @header_size 12
  @iv_size 16
  @tag_size 16

  for {region, offset} <- [
        iv: @header_size,
        tag: @header_size + @iv_size,
        ciphertext: @header_size + @iv_size + @tag_size
      ] do
    test "loads a value with a tampered #{region} as nil" do
      assert Binary.load(flip_bit(@cloak_ciphertext, unquote(offset))) == {:ok, nil}
    end
  end

  test "loads a truncated value as nil" do
    truncated = binary_part(@cloak_ciphertext, 0, byte_size(@cloak_ciphertext) - 1)
    assert Binary.load(truncated) == {:ok, nil}
  end

  test "loads a value with an unknown header as nil" do
    assert Binary.load(flip_bit(@cloak_ciphertext, 2)) == {:ok, nil}
  end

  test "loads a value encrypted with another key as nil" do
    assert Binary.load(@other_key_ciphertext) == {:ok, nil}
  end

  test "loads a value written by Cloak" do
    assert Binary.load(@cloak_ciphertext) == {:ok, "secret_cookie"}
  end

  defp flip_bit(value, offset) do
    <<prefix::binary-size(^offset), byte, rest::binary>> = value
    <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end
end
