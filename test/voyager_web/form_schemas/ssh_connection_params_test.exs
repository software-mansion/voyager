defmodule VoyagerWeb.FormSchemas.SshConnectionParamsTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.FormSchemas.SshConnectionParams

  defp valid_attrs do
    %{
      "ssh_user" => "alice",
      "ssh_host" => "bastion.example.com",
      "ssh_port" => "22",
      "node_name" => "myapp@10.0.0.5",
      "cookie" => "s3cret",
      "auth_method" => "agent"
    }
  end

  describe "changeset/1" do
    test "accepts valid attrs" do
      changeset = SshConnectionParams.changeset(valid_attrs())
      assert changeset.valid?
    end

    test "accepts password auth with password provided" do
      attrs = Map.merge(valid_attrs(), %{"auth_method" => "password", "password" => "mypass"})
      changeset = SshConnectionParams.changeset(attrs)
      assert changeset.valid?
    end

    test "requires ssh_user" do
      changeset = SshConnectionParams.changeset(Map.delete(valid_attrs(), "ssh_user"))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :ssh_user)
    end

    test "requires ssh_host" do
      changeset = SshConnectionParams.changeset(Map.delete(valid_attrs(), "ssh_host"))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :ssh_host)
    end

    test "requires node_name" do
      changeset = SshConnectionParams.changeset(Map.delete(valid_attrs(), "node_name"))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :node_name)
    end

    test "requires cookie" do
      changeset = SshConnectionParams.changeset(Map.delete(valid_attrs(), "cookie"))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :cookie)
    end

    test "validates node_name format requires name@host" do
      changeset = SshConnectionParams.changeset(%{valid_attrs() | "node_name" => "noatsign"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :node_name)
    end

    test "validates node_name format accepts name@host" do
      changeset =
        SshConnectionParams.changeset(%{valid_attrs() | "node_name" => "app@192.168.1.1"})

      assert changeset.valid?
    end

    test "validates ssh_port minimum of 1" do
      changeset = SshConnectionParams.changeset(%{valid_attrs() | "ssh_port" => "0"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :ssh_port)
    end

    test "validates ssh_port maximum of 65535" do
      changeset = SshConnectionParams.changeset(%{valid_attrs() | "ssh_port" => "65536"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :ssh_port)
    end

    test "validates epmd_port minimum of 1" do
      changeset = SshConnectionParams.changeset(Map.merge(valid_attrs(), %{"epmd_port" => "0"}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :epmd_port)
    end

    test "validates epmd_port maximum of 65535" do
      changeset =
        SshConnectionParams.changeset(Map.merge(valid_attrs(), %{"epmd_port" => "70000"}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :epmd_port)
    end

    test "requires password when auth_method is :password" do
      attrs = Map.merge(valid_attrs(), %{"auth_method" => "password"})
      changeset = SshConnectionParams.changeset(attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :password)
    end

    test "does not require password when auth_method is :agent" do
      changeset = SshConnectionParams.changeset(valid_attrs())
      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :password)
    end

    test "enforces length limit on ssh_user" do
      attrs = %{valid_attrs() | "ssh_user" => String.duplicate("a", 256)}
      changeset = SshConnectionParams.changeset(attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :ssh_user)
    end

    test "enforces length limit on node_name" do
      attrs = %{valid_attrs() | "node_name" => String.duplicate("a", 252) <> "@host"}
      changeset = SshConnectionParams.changeset(attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :node_name)
    end
  end

  describe "to_auth/1" do
    test "returns :agent for agent auth_method" do
      {:ok, params} =
        SshConnectionParams.changeset(valid_attrs())
        |> Ecto.Changeset.apply_action(:insert)

      assert SshConnectionParams.to_auth(params) == :agent
    end

    test "returns {:password, pw} for password auth_method" do
      attrs = Map.merge(valid_attrs(), %{"auth_method" => "password", "password" => "s3cr3t"})

      {:ok, params} =
        SshConnectionParams.changeset(attrs)
        |> Ecto.Changeset.apply_action(:insert)

      assert SshConnectionParams.to_auth(params) == {:password, "s3cr3t"}
    end
  end
end
