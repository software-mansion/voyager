defmodule DualTcpDistTest do
  use ExUnit.Case, async: true

  describe "choose_driver/1" do
    test "an IPv4 literal host selects the dual_tcp driver" do
      assert :dual_tcp_dist.choose_driver(:"voyager@127.0.0.1") == :dual_tcp
    end

    test "an IPv6 literal host selects the inet6_tcp driver" do
      assert :dual_tcp_dist.choose_driver(:"target@::1") == :inet6_tcp
    end

    test "a malformed / unreachable node falls back to dual_tcp" do
      assert :dual_tcp_dist.choose_driver(:noatsign) == :dual_tcp
    end
  end

  describe "select/1" do
    test "claims IPv4 targets" do
      assert :dual_tcp_dist.select(:"voyager@127.0.0.1")
    end

    test "claims IPv6 targets (net_kernel would otherwise reject them)" do
      assert :dual_tcp_dist.select(:"target@::1")
    end

    test "rejects malformed node names" do
      refute :dual_tcp_dist.select(:noatsign)
    end
  end
end
