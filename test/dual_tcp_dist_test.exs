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

  test "only replies to our own calls and ticks pass the filter" do
    assert :dual_tcp_dist.allowed(<<>>)
    assert :dual_tcp_dist.allowed(frame({21, self(), self(), make_ref(), :result}))
    assert :dual_tcp_dist.allowed(frame({31, make_ref(), self(), 2, self()}))
    assert :dual_tcp_dist.allowed(frame({31, make_ref(), self(), 0, :notsup}))
    refute :dual_tcp_dist.allowed(frame({31, make_ref(), self(), 1, self()}))
    refute :dual_tcp_dist.allowed(frame({31, make_ref(), self(), 3, self()}))
    refute :dual_tcp_dist.allowed(frame({31, make_ref(), self(), Integer.pow(2, 70) + 1, self()}))
    refute :dual_tcp_dist.allowed(frame({32, make_ref(), self(), 2, self(), []}))
    refute :dual_tcp_dist.allowed(frame({29, make_ref(), self(), self(), {:os, :cmd, 1}, []}))
    refute :dual_tcp_dist.allowed(frame({6, self(), :"", :rex}))
    refute :dual_tcp_dist.allowed(frame({2, :"", self()}))
    refute :dual_tcp_dist.allowed(frame({8, self(), self(), :kill}))
    refute :dual_tcp_dist.allowed(<<68, 0>>)
  end

  test "a spawn reply must be a complete, small control term with known atoms" do
    reply = frame({31, make_ref(), self(), 2, self()})

    refute :dual_tcp_dist.allowed(reply <> :erlang.term_to_binary(:payload))
    refute :dual_tcp_dist.allowed(binary_part(reply, 0, byte_size(reply) - 1))

    refute :dual_tcp_dist.allowed(
             frame({31, make_ref(), self(), 2, :crypto.strong_rand_bytes(4096)})
           )

    unknown_atom = <<119, 25, "dual_tcp_no_such_atom_xyz">>
    control = <<131, 104, 5, 97, 31, 106, 106, 97, 2, unknown_atom::binary>>
    refute :dual_tcp_dist.allowed(<<112, control::binary>>)
  end

  defp frame(control), do: <<112, :erlang.term_to_binary(control)::binary>>
end
