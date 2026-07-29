defmodule Voyager.ConnectionsTest do
  @moduledoc false
  use Voyager.DataCase, async: false

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Schemas.Connection

  describe "upsert_connected/2" do
    test "inserts a new connection" do
      assert {:ok, conn} =
               ConnectionActions.upsert_connected("my_app@127.0.0.1", cookie: "secret")

      assert conn.node_name == "my_app@127.0.0.1"
      assert conn.cookie == "secret"
      assert conn.pinned == false
      assert %DateTime{} = conn.last_connected_at
    end

    test "updates last_connected_at on conflict" do
      old_time = ~U[2020-01-01 00:00:00Z]

      {:ok, original} =
        %Connection{}
        |> Connection.changeset(%{
          node_name: "dup@127.0.0.1",
          cookie: "c1",
          last_connected_at: old_time
        })
        |> Repo.insert()

      {:ok, updated} = ConnectionActions.upsert_connected("dup@127.0.0.1", cookie: "c2")

      assert updated.id == original.id
      assert DateTime.compare(updated.last_connected_at, original.last_connected_at) == :gt
    end

    test "overwrites cookie when a new cookie is supplied" do
      {:ok, _} = ConnectionActions.upsert_connected("c@127.0.0.1", cookie: "old")
      {:ok, _} = ConnectionActions.upsert_connected("c@127.0.0.1", cookie: "new")

      assert ConnectionQueries.get_by_node_name("c@127.0.0.1").cookie == "new"
    end

    test "preserves existing cookie when no cookie is supplied" do
      {:ok, _} = ConnectionActions.upsert_connected("k@127.0.0.1", cookie: "keep-me")
      {:ok, _} = ConnectionActions.upsert_connected("k@127.0.0.1")

      assert ConnectionQueries.get_by_node_name("k@127.0.0.1").cookie == "keep-me"
    end

    test "defaults name_type to :longnames" do
      {:ok, conn} = ConnectionActions.upsert_connected("nt@127.0.0.1", cookie: "x")
      assert conn.name_type == :longnames
    end

    test "stores the given name_type" do
      {:ok, conn} =
        ConnectionActions.upsert_connected("nt@127.0.0.1", cookie: "x", name_type: :shortnames)

      assert conn.name_type == :shortnames
      assert ConnectionQueries.get_by_node_name("nt@127.0.0.1").name_type == :shortnames
    end

    test "updates name_type on conflict" do
      {:ok, _} =
        ConnectionActions.upsert_connected("ntc@127.0.0.1", cookie: "x", name_type: :longnames)

      {:ok, _} =
        ConnectionActions.upsert_connected("ntc@127.0.0.1", cookie: "x", name_type: :shortnames)

      assert ConnectionQueries.get_by_node_name("ntc@127.0.0.1").name_type == :shortnames
    end

    test "cookie is encrypted at rest" do
      {:ok, _} = ConnectionActions.upsert_connected("enc@127.0.0.1", cookie: "plaintext-cookie")

      [raw] = Repo.all(from c in "connections", select: c.cookie)

      refute raw == "plaintext-cookie"
      assert is_binary(raw)
      assert byte_size(raw) > byte_size("plaintext-cookie")

      assert ConnectionQueries.get_by_node_name("enc@127.0.0.1").cookie == "plaintext-cookie"
    end
  end

  describe "all/0" do
    test "returns pinned rows first, then by last_connected_at desc" do
      old_time = ~U[2020-01-01 00:00:00Z]
      recent_time = ~U[2020-01-02 00:00:00Z]

      {:ok, old_recent} =
        %Connection{}
        |> Connection.changeset(%{node_name: "a@h", cookie: "x", last_connected_at: old_time})
        |> Repo.insert()

      {:ok, _new_recent} =
        %Connection{}
        |> Connection.changeset(%{node_name: "b@h", cookie: "x", last_connected_at: recent_time})
        |> Repo.insert()

      {:ok, pinned} =
        %Connection{}
        |> Connection.changeset(%{node_name: "c@h", cookie: "x", last_connected_at: recent_time})
        |> Repo.insert()

      ConnectionActions.pin(pinned.id)

      names = Enum.map(ConnectionQueries.all(), & &1.node_name)

      assert names == ["c@h", "b@h", "a@h"]
      assert old_recent.node_name == "a@h"
    end
  end

  describe "pin/1, unpin/1, delete/1" do
    test "pin/1 sets pinned=true, unpin/1 sets pinned=false" do
      {:ok, conn} = ConnectionActions.upsert_connected("p@h", cookie: "x")

      {:ok, pinned} = ConnectionActions.pin(conn.id)
      assert pinned.pinned == true

      {:ok, unpinned} = ConnectionActions.unpin(conn.id)
      assert unpinned.pinned == false
    end

    test "pin/1, unpin/1, delete/1 return :not_found on missing id" do
      assert {:error, :not_found} = ConnectionActions.pin(-1)
      assert {:error, :not_found} = ConnectionActions.unpin(-1)
      assert {:error, :not_found} = ConnectionActions.delete(-1)
    end

    test "delete/1 removes the row" do
      {:ok, conn} = ConnectionActions.upsert_connected("d@h", cookie: "x")
      {:ok, _} = ConnectionActions.delete(conn.id)

      assert Repo.get(Connection, conn.id) == nil
    end
  end

  describe "get/1" do
    test "returns nil for missing id rather than raising" do
      assert ConnectionQueries.get(-1) == nil
    end
  end
end
