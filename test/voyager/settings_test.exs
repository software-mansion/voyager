defmodule Voyager.SettingsTest do
  use Voyager.DataCase, async: false

  alias Voyager.Schemas.Setting
  alias Voyager.Settings

  describe "get/2" do
    test "returns the default when the key is absent" do
      assert Settings.get(:missing_key, 4040) == 4040
    end

    test "reads a value persisted to the database" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)
      assert Settings.get(:mcp_port, 4040) == 5050
    end

    test "prefers application config over the database" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)

      Application.put_env(:voyager, :mcp_port, 6060)
      on_exit(fn -> Application.delete_env(:voyager, :mcp_port) end)

      assert Settings.get(:mcp_port, 4040) == 6060
    end
  end

  describe "put/2" do
    test "upserts a setting in the database" do
      assert {:ok, %Setting{}} = Settings.put(:mcp_port, 5050)
      assert {:ok, %Setting{}} = Settings.put(:mcp_port, 5051)
      assert Settings.get(:mcp_port) == 5051
    end

    test "returns {:error, :locked} when the key is set in application config" do
      Application.put_env(:voyager, :mcp_port, 6060)
      on_exit(fn -> Application.delete_env(:voyager, :mcp_port) end)

      assert {:error, :locked} = Settings.put(:mcp_port, 7070)
    end

    test "rejects invalid changesets" do
      assert {:error, %Ecto.Changeset{}} =
               %Setting{}
               |> Setting.changeset(%{})
               |> Voyager.Repo.insert()
    end

    test "broadcasts setting_changed after a successful put with broadcast?: true" do
      Phoenix.PubSub.subscribe(Voyager.PubSub, Settings.topic(:pid_format))

      assert {:ok, _} = Settings.put(:pid_format, :local, broadcast?: true)
      assert_receive {:setting_changed, :pid_format, :local}
    end

    test "does not broadcast when broadcast?: false" do
      Phoenix.PubSub.subscribe(Voyager.PubSub, Settings.topic(:pid_format))

      assert {:ok, _} = Settings.put(:pid_format, :local, broadcast?: false)
      refute_received {:setting_changed, :pid_format, _}
    end

    test "does not broadcast when the key is locked" do
      Application.put_env(:voyager, :pid_format, :distribution)
      on_exit(fn -> Application.delete_env(:voyager, :pid_format) end)

      Phoenix.PubSub.subscribe(Voyager.PubSub, Settings.topic(:pid_format))

      assert {:error, :locked} = Settings.put(:pid_format, :local)
      refute_received {:setting_changed, :pid_format, _}
    end
  end

  describe "locked?/1" do
    test "is false when the key is only stored in the database" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)
      refute Settings.locked?(:mcp_port)
    end

    test "is true when the key is set in application config" do
      Application.put_env(:voyager, :mcp_ip, {127, 0, 0, 1})
      on_exit(fn -> Application.delete_env(:voyager, :mcp_ip) end)

      assert Settings.locked?(:mcp_ip)
    end
  end

  describe "all/0" do
    test "returns all persisted settings decoded" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)
      assert {:ok, _} = Settings.put(:mcp_ip, {127, 0, 0, 1})

      assert %{"mcp_port" => 5050, "mcp_ip" => {127, 0, 0, 1}} = Settings.all()
    end
  end
end
