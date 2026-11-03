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

  defp host(attrs \\ %{}) do
    Map.merge(
      %{
        alias: "prod",
        host_name: nil,
        user: nil,
        port: nil,
        identity_files: [],
        identity_agent: nil
      },
      attrs
    )
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

    test "requires key_path when auth_method is :key" do
      changeset = SshConnectionParams.changeset(Map.put(valid_attrs(), "auth_method", "key"))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :key_path)
    end

    test "does not cast the passphrase from form params" do
      attrs =
        Map.merge(valid_attrs(), %{
          "auth_method" => "key",
          "key_path" => "~/.ssh/id_rsa",
          "passphrase" => "from-the-form"
        })

      changeset = SshConnectionParams.changeset(attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :passphrase) == nil
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
    test "returns {:agent, nil} for agent auth_method" do
      {:ok, params} =
        SshConnectionParams.changeset(valid_attrs())
        |> Ecto.Changeset.apply_action(:insert)

      assert SshConnectionParams.to_auth(params) == {:agent, nil}
    end

    test "returns {:agent, socket_path} when an agent socket is set" do
      attrs = Map.put(valid_attrs(), "agent_socket_path", "~/.1password/agent.sock")

      {:ok, params} =
        SshConnectionParams.changeset(attrs)
        |> Ecto.Changeset.apply_action(:insert)

      assert SshConnectionParams.to_auth(params) == {:agent, "~/.1password/agent.sock"}
    end

    test "returns {:password, pw} for password auth_method" do
      attrs = Map.merge(valid_attrs(), %{"auth_method" => "password", "password" => "s3cr3t"})

      {:ok, params} =
        SshConnectionParams.changeset(attrs)
        |> Ecto.Changeset.apply_action(:insert)

      assert SshConnectionParams.to_auth(params) == {:password, "s3cr3t"}
    end
  end

  describe "params_from_host/1" do
    test "uses host_name for ssh_host" do
      params = SshConnectionParams.params_from_host(host(%{host_name: "10.0.0.5"}))
      assert params["ssh_host"] == "10.0.0.5"
    end

    test "falls back to the alias for ssh_host" do
      assert SshConnectionParams.params_from_host(host())["ssh_host"] == "prod"
    end

    test "uses user for ssh_user, blank when unset" do
      assert SshConnectionParams.params_from_host(host(%{user: "deploy"}))["ssh_user"] == "deploy"
      assert SshConnectionParams.params_from_host(host())["ssh_user"] == ""
    end

    test "uses port for ssh_port, 22 when unset" do
      assert SshConnectionParams.params_from_host(host(%{port: 2222}))["ssh_port"] == "2222"
      assert SshConnectionParams.params_from_host(host())["ssh_port"] == "22"
    end

    test "uses the first identity file for key_path, blank when there is none" do
      params = SshConnectionParams.params_from_host(host(%{identity_files: ["/k/a", "/k/b"]}))

      assert params["key_path"] == "/k/a"
      assert SshConnectionParams.params_from_host(host())["key_path"] == ""
    end

    test "uses an identity_agent path for agent_socket_path" do
      params = SshConnectionParams.params_from_host(host(%{identity_agent: "/a/agent.sock"}))
      assert params["agent_socket_path"] == "/a/agent.sock"
    end

    test "leaves agent_socket_path blank for identity_agent none and nil" do
      params = SshConnectionParams.params_from_host(host(%{identity_agent: :none}))

      assert params["agent_socket_path"] == ""
      assert SshConnectionParams.params_from_host(host())["agent_socket_path"] == ""
    end

    test "fills both key_path and agent_socket_path and does not set auth_method" do
      params =
        SshConnectionParams.params_from_host(
          host(%{identity_files: ["/k/a"], identity_agent: "/a/agent.sock"})
        )

      assert %{"key_path" => "/k/a", "agent_socket_path" => "/a/agent.sock"} = params
      refute Map.has_key?(params, "auth_method")
    end
  end
end
