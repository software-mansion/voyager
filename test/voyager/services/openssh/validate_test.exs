defmodule Voyager.Services.OpenSSH.ValidateTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.OpenSSH.Validate

  describe "host/1" do
    test "accepts hostnames, IPv4 and IPv6 literals" do
      assert {:ok, "example.com"} = Validate.host("example.com")
      assert {:ok, "127.0.0.1"} = Validate.host("127.0.0.1")
      assert {:ok, "::1"} = Validate.host("::1")
      assert {:ok, "my-bastion_1"} = Validate.host("my-bastion_1")
    end

    test "rejects values beginning with '-' (ssh option injection)" do
      assert {:error, {:invalid_host, _}} = Validate.host("-oProxyCommand=touch /tmp/x")
      assert {:error, {:invalid_host, _}} = Validate.host("-J jump")
    end

    test "rejects whitespace and shell metacharacters" do
      assert {:error, {:invalid_host, _}} = Validate.host("a b")
      assert {:error, {:invalid_host, _}} = Validate.host("a;b")
      assert {:error, {:invalid_host, _}} = Validate.host("")
    end
  end

  describe "user/1" do
    test "accepts normal usernames" do
      assert {:ok, "deploy"} = Validate.user("deploy")
      assert {:ok, "app_user-1"} = Validate.user("app_user-1")
    end

    test "rejects option injection and bad characters" do
      assert {:error, {:invalid_user, _}} = Validate.user("-oProxyCommand=x")
      assert {:error, {:invalid_user, _}} = Validate.user("a@b")
      assert {:error, {:invalid_user, _}} = Validate.user("a b")
    end
  end

  describe "node_name/1" do
    test "accepts valid node names and rejects injection / @" do
      assert {:ok, "myapp"} = Validate.node_name("myapp")
      assert {:error, {:invalid_node_name, _}} = Validate.node_name("-evil")
      assert {:error, {:invalid_node_name, _}} = Validate.node_name("myapp@host")
    end

    test "rejects values over the 255-byte atom limit" do
      assert {:error, {:invalid_node_name, _}} = Validate.node_name(String.duplicate("a", 256))
    end
  end
end
