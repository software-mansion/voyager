defmodule Voyager.Services.Ets.FetchTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Ets.Fetch

  @node :"peer@127.0.0.1"
  @timeout 3_000

  test "propagates :invalid_limit without a remote call" do
    assert {:error, :invalid_limit} = Fetch.select_chunk(@node, :t, 15, nil, @timeout)
  end

  test "propagates :invalid_table without a remote call" do
    assert {:error, :invalid_table} = Fetch.select_chunk(@node, self(), 10, nil, @timeout)
  end

  test "propagates :invalid_key without a remote call" do
    assert {:error, :invalid_key} = Fetch.lookup(@node, :t, {:tuple, 1}, @timeout)
  end
end
