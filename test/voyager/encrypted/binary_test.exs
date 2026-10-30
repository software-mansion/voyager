defmodule Voyager.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias Voyager.Encrypted.Binary

  @cloak_ciphertext Base.decode64!(
                      "AQpBRVMuR0NNLlYxNJ4NtPc/OFT+2n08guR956qz3B6NNFw1B1Mv07iVBfZ4uqit1p3q+g93+hL4"
                    )

  test "loads a value written by Cloak" do
    assert Binary.load(@cloak_ciphertext) == {:ok, "secret_cookie"}
  end
end
