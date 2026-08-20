defmodule DualTcpDistTest do
  @moduledoc """
  Unit tests for the pure family-selection logic of the `dual_tcp_dist`
  distribution carrier.

  These exercise only the parts that resolve loopback literals via
  `inet:getaddr/2` — no distribution, epmd daemon, or booted node is needed.
  The end-to-end "connect to a live v4 and v6 node" behaviour is covered by
  the e2e suite, since it only exists once wired into a VM's `-proto_dist`.
  """
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

  describe "family_of/1" do
    test "a size-4 tuple is inet" do
      assert :dual_tcp_dist.family_of({127, 0, 0, 1}) == :inet
    end

    test "a size-8 tuple is inet6" do
      assert :dual_tcp_dist.family_of({0, 0, 0, 0, 0, 0, 0, 1}) == :inet6
    end

    test "any other shape is undefined" do
      assert :dual_tcp_dist.family_of({1, 2, 3}) == :undefined
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
