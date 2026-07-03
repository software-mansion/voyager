defmodule Voyager.ValidateTest do
  use ExUnit.Case, async: true

  alias Voyager.Validate

  describe "host/1" do
    test "accepts hostnames, IPv4, and IPv6 literals" do
      assert :ok = Validate.host("example.com")
      assert :ok = Validate.host("10.0.0.5")
      assert :ok = Validate.host("fe80::1")
    end

    test "accepts short hostnames" do
      assert :ok = Validate.host("myhost")
    end

    test "rejects option-injection and shell metacharacters" do
      assert {:error, {:invalid_host, "-oProxyCommand=x"}} = Validate.host("-oProxyCommand=x")
      assert {:error, {:invalid_host, "a b"}} = Validate.host("a b")
      assert {:error, {:invalid_host, ""}} = Validate.host("")
    end
  end

  describe "node_name/1" do
    test "accepts a name@host value" do
      assert :ok = Validate.node_name("myapp@10.0.0.5")
    end

    test "accepts short node names" do
      assert :ok = Validate.node_name("myapp@myhost")
    end

    test "rejects values without a host part" do
      assert {:error, {:invalid_node_name, "myapp"}} = Validate.node_name("myapp")
    end

    test "rejects values longer than the atom limit" do
      long = String.duplicate("a", 256) <> "@host"
      assert {:error, {:invalid_node_name, ^long}} = Validate.node_name(long)
    end
  end
end
