defmodule Voyager.ValidateTest do
  use ExUnit.Case, async: true

  alias Voyager.Validate

  describe "host/1" do
    test "accepts hostnames, IPv4, and IPv6 literals" do
      assert {:ok, "example.com"} = Validate.host("example.com")
      assert {:ok, "10.0.0.5"} = Validate.host("10.0.0.5")
      assert {:ok, "fe80::1"} = Validate.host("fe80::1")
    end

    test "rejects option-injection and shell metacharacters" do
      assert {:error, {:invalid_host, "-oProxyCommand=x"}} = Validate.host("-oProxyCommand=x")
      assert {:error, {:invalid_host, "a b"}} = Validate.host("a b")
      assert {:error, {:invalid_host, ""}} = Validate.host("")
    end
  end

  describe "node_name/1" do
    test "accepts a name@host value" do
      assert {:ok, "myapp@10.0.0.5"} = Validate.node_name("myapp@10.0.0.5")
    end

    test "rejects values without a host part" do
      assert {:error, {:invalid_node_name, "myapp"}} = Validate.node_name("myapp")
    end

    test "rejects values longer than the atom limit" do
      long = String.duplicate("a", 256) <> "@host"
      assert {:error, {:invalid_node_name, ^long}} = Validate.node_name(long)
    end
  end

  describe "epmd_prefix/1" do
    test "accepts an empty prefix" do
      assert {:ok, ""} = Validate.epmd_prefix("")
    end

    test "accepts paths and shell env-var assignments" do
      assert {:ok, "/opt/homebrew/bin"} = Validate.epmd_prefix("/opt/homebrew/bin")
      assert {:ok, "~/bin"} = Validate.epmd_prefix("~/bin")

      prefix = "PATH=$HOME/.local/share/mise/shims:$PATH"
      assert {:ok, ^prefix} = Validate.epmd_prefix(prefix)
    end

    test "rejects command-chaining and substitution metacharacters" do
      assert {:error, {:invalid_epmd_prefix, "; rm -rf /"}} = Validate.epmd_prefix("; rm -rf /")
      assert {:error, {:invalid_epmd_prefix, "$(whoami)"}} = Validate.epmd_prefix("$(whoami)")
      assert {:error, {:invalid_epmd_prefix, "a | b"}} = Validate.epmd_prefix("a | b")
      assert {:error, {:invalid_epmd_prefix, "a && b"}} = Validate.epmd_prefix("a && b")
    end
  end
end
