defmodule DualTcpDistTest do
  use ExUnit.Case, async: true

  test "parse_address/1 accepts IPv4 and IPv6 literals" do
    assert {:ok, {10, 0, 0, 5}} = :dual_tcp_dist.parse_address(~c"10.0.0.5")
    assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = :dual_tcp_dist.parse_address(~c"::1")
  end

  test "parse_address/1 rejects hostnames" do
    assert {:error, _} = :dual_tcp_dist.parse_address(~c"myhost")
  end

  test "select/1 claims IPv4 and IPv6 nodes" do
    assert :dual_tcp_dist.select(:"app@127.0.0.1")
    assert :dual_tcp_dist.select(:"app@::1")
  end

  test "select/1 rejects malformed node names" do
    refute :dual_tcp_dist.select(:noatsign)
  end
end
