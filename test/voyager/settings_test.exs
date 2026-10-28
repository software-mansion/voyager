defmodule Voyager.SettingsTest do
  use Voyager.DataCase, async: false

  import Voyager.TestUtils, only: [reset_cached_setting: 1]

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

  @choices [:small, :medium, :large]
  @cache_key {__MODULE__, :test_size}

  defp get_cached_choice,
    do: Settings.get_cached_choice(:test_size, @choices, :medium, @cache_key)

  describe "get_cached_choice/4" do
    setup do: reset_cached_setting(@cache_key)

    test "returns a saved value that is one of the choices" do
      assert {:ok, _} = Settings.put(:test_size, :large)
      assert get_cached_choice() == :large
    end

    test "returns the default for a saved value outside the choices" do
      assert {:ok, _} = Settings.put(:test_size, :huge)
      assert get_cached_choice() == :medium
    end

    test "returns the default when nothing is saved" do
      assert get_cached_choice() == :medium
    end

    test "keeps the first value read until the cache is replaced" do
      assert get_cached_choice() == :medium
      assert {:ok, _} = Settings.put(:test_size, :large)
      assert get_cached_choice() == :medium
    end
  end

  describe "save_with_cache/3" do
    setup do: reset_cached_setting(@cache_key)

    test "saves the value and caches it" do
      assert Settings.save_with_cache(:test_size, :large, @cache_key) == :ok

      assert Settings.get(:test_size) == :large
      assert get_cached_choice() == :large
    end

    test "leaves the cache alone when the key is locked" do
      Application.put_env(:voyager, :test_size, :small)
      on_exit(fn -> Application.delete_env(:voyager, :test_size) end)

      assert Settings.save_with_cache(:test_size, :large, @cache_key) == {:error, :locked}
      assert :persistent_term.get(@cache_key, nil) == nil
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
  end

  describe "locked?/1" do
    test "is false when the key is only stored in the database" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)
      refute Settings.locked?(:mcp_port)
    end

    test "is true when the key is set in application config" do
      Application.put_env(:voyager, :mcp_enabled, true)
      on_exit(fn -> Application.delete_env(:voyager, :mcp_enabled) end)

      assert Settings.locked?(:mcp_enabled)
    end
  end

  describe "all/0" do
    test "returns all persisted settings decoded" do
      assert {:ok, _} = Settings.put(:mcp_port, 5050)
      assert {:ok, _} = Settings.put(:mcp_enabled, false)

      assert %{"mcp_port" => 5050, "mcp_enabled" => false} = Settings.all()
    end
  end
end
