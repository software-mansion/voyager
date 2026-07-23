defmodule Voyager.SshConnectionsTest do
  @moduledoc false
  use Voyager.DataCase, async: true

  import Ecto.Query

  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Schemas.SshConnection

  @base_profile {"deploy", "10.0.0.1", 22, "app@10.0.0.1"}

  defp insert_profile(ssh_user, ssh_host, ssh_port, node_name, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          ssh_user: ssh_user,
          ssh_host: ssh_host,
          ssh_port: ssh_port,
          node_name: node_name,
          last_connected_at: ~U[2020-01-01 00:00:00Z]
        },
        extra
      )

    %SshConnection{}
    |> SshConnection.changeset(attrs)
    |> Repo.insert!()
  end

  describe "upsert_connected/5" do
    test "inserts a new ssh connection" do
      {user, host, port, node} = @base_profile

      assert {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)

      assert conn.ssh_user == user
      assert conn.ssh_host == host
      assert conn.ssh_port == port
      assert conn.node_name == node
      assert conn.pinned == false
      assert %DateTime{} = conn.last_connected_at
    end

    test "defaults auth_method to :agent" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)
      assert conn.auth_method == :agent
    end

    test "defaults name_type to :longnames" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)
      assert conn.name_type == :longnames
    end

    test "defaults epmd_port to 4369" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)
      assert conn.epmd_port == 4369
    end

    test "stores given auth_method" do
      {user, host, port, node} = @base_profile

      {:ok, conn} =
        SshConnectionActions.upsert_connected(user, host, port, node,
          auth_method: :password,
          password: "s3cret"
        )

      assert conn.auth_method == :password
      assert SshConnectionQueries.get_by_profile(user, host, port, node).auth_method == :password
    end

    test "stores given name_type" do
      {user, host, port, node} = @base_profile

      {:ok, conn} =
        SshConnectionActions.upsert_connected(user, host, port, node, name_type: :shortnames)

      assert conn.name_type == :shortnames
      assert SshConnectionQueries.get_by_profile(user, host, port, node).name_type == :shortnames
    end

    test "stores given epmd_port" do
      {user, host, port, node} = @base_profile

      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node, epmd_port: 5678)

      assert conn.epmd_port == 5678
      assert SshConnectionQueries.get_by_profile(user, host, port, node).epmd_port == 5678
    end

    test "updates last_connected_at on conflict" do
      {user, host, port, node} = @base_profile
      original = insert_profile(user, host, port, node)

      {:ok, updated} = SshConnectionActions.upsert_connected(user, host, port, node)

      assert updated.id == original.id
      assert DateTime.compare(updated.last_connected_at, original.last_connected_at) == :gt
    end

    test "overwrites cookie when a new cookie is supplied" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, cookie: "old")
      SshConnectionActions.upsert_connected(user, host, port, node, cookie: "new")

      assert SshConnectionQueries.get_by_profile(user, host, port, node).cookie == "new"
    end

    test "preserves existing cookie when no cookie is supplied" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, cookie: "keep-me")
      SshConnectionActions.upsert_connected(user, host, port, node)

      assert SshConnectionQueries.get_by_profile(user, host, port, node).cookie == "keep-me"
    end

    test "overwrites password when a new password is supplied" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, password: "old-pass")
      SshConnectionActions.upsert_connected(user, host, port, node, password: "new-pass")

      assert SshConnectionQueries.get_by_profile(user, host, port, node).password == "new-pass"
    end

    test "preserves existing password when no password is supplied" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, password: "keep-pass")
      SshConnectionActions.upsert_connected(user, host, port, node)

      assert SshConnectionQueries.get_by_profile(user, host, port, node).password == "keep-pass"
    end

    test "updates name_type on conflict" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, name_type: :longnames)
      SshConnectionActions.upsert_connected(user, host, port, node, name_type: :shortnames)

      assert SshConnectionQueries.get_by_profile(user, host, port, node).name_type == :shortnames
    end

    test "updates auth_method on conflict" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, auth_method: :agent)

      SshConnectionActions.upsert_connected(user, host, port, node,
        auth_method: :password,
        password: "new"
      )

      assert SshConnectionQueries.get_by_profile(user, host, port, node).auth_method == :password
    end

    test "cookie is encrypted at rest" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, cookie: "plaintext-cookie")

      [raw] = Repo.all(from c in "ssh_connections", select: c.cookie)

      refute raw == "plaintext-cookie"
      assert is_binary(raw)
      assert byte_size(raw) > byte_size("plaintext-cookie")

      assert SshConnectionQueries.get_by_profile(user, host, port, node).cookie ==
               "plaintext-cookie"
    end

    test "password is encrypted at rest" do
      {user, host, port, node} = @base_profile
      SshConnectionActions.upsert_connected(user, host, port, node, password: "plaintext-pass")

      [raw] = Repo.all(from c in "ssh_connections", select: c.password)

      refute raw == "plaintext-pass"
      assert is_binary(raw)
      assert byte_size(raw) > byte_size("plaintext-pass")

      assert SshConnectionQueries.get_by_profile(user, host, port, node).password ==
               "plaintext-pass"
    end

    test "different node_names on same host create separate records" do
      {:ok, _} = SshConnectionActions.upsert_connected("deploy", "h", 22, "app1@h")
      {:ok, _} = SshConnectionActions.upsert_connected("deploy", "h", 22, "app2@h")

      assert SshConnectionQueries.get_by_profile("deploy", "h", 22, "app1@h") != nil
      assert SshConnectionQueries.get_by_profile("deploy", "h", 22, "app2@h") != nil
    end
  end

  describe "all/0" do
    test "returns pinned rows first, then by last_connected_at desc" do
      old_time = ~U[2020-01-01 00:00:00Z]
      recent_time = ~U[2020-01-02 00:00:00Z]

      insert_profile("u", "h", 22, "a@h", %{last_connected_at: old_time})
      insert_profile("u", "h", 22, "b@h", %{last_connected_at: recent_time})
      pinned = insert_profile("u", "h", 22, "c@h", %{last_connected_at: recent_time})

      SshConnectionActions.pin(pinned.id)

      names = Enum.map(SshConnectionQueries.all(), & &1.node_name)

      assert names == ["c@h", "b@h", "a@h"]
    end
  end

  describe "pin/1, unpin/1, delete/1" do
    test "pin/1 sets pinned=true, unpin/1 sets pinned=false" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)

      {:ok, pinned} = SshConnectionActions.pin(conn.id)
      assert pinned.pinned == true

      {:ok, unpinned} = SshConnectionActions.unpin(conn.id)
      assert unpinned.pinned == false
    end

    test "pin/1, unpin/1, delete/1 return :not_found on missing id" do
      assert {:error, :not_found} = SshConnectionActions.pin(-1)
      assert {:error, :not_found} = SshConnectionActions.unpin(-1)
      assert {:error, :not_found} = SshConnectionActions.delete(-1)
    end

    test "delete/1 removes the row" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)
      {:ok, _} = SshConnectionActions.delete(conn.id)

      assert Repo.get(SshConnection, conn.id) == nil
    end
  end

  describe "get/1" do
    test "returns nil for missing id rather than raising" do
      assert SshConnectionQueries.get(-1) == nil
    end
  end

  describe "get_by_profile/4" do
    test "returns nil when no matching profile exists" do
      assert SshConnectionQueries.get_by_profile("nobody", "nowhere", 22, "app@x") == nil
    end

    test "returns the record for a matching profile" do
      {user, host, port, node} = @base_profile
      {:ok, conn} = SshConnectionActions.upsert_connected(user, host, port, node)

      found = SshConnectionQueries.get_by_profile(user, host, port, node)
      assert found.id == conn.id
    end
  end
end
