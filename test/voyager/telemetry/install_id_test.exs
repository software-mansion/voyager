defmodule Voyager.Telemetry.InstallIdTest do
  use Voyager.DataCase, async: false

  alias Voyager.Settings
  alias Voyager.Telemetry.InstallId

  setup do
    InstallId.clear_cache()
    on_exit(&InstallId.clear_cache/0)
    :ok
  end

  test "generates and persists a uuid on first call" do
    install_id = InstallId.get()

    assert {:ok, _uuid} = Ecto.UUID.cast(install_id)
    assert Settings.get(:install_id) == install_id
  end

  test "returns the same id on subsequent calls" do
    install_id = InstallId.get()

    InstallId.clear_cache()

    assert InstallId.get() == install_id
    assert InstallId.get() == install_id
  end

  test "reuses an already persisted id instead of generating a new one" do
    {:ok, _setting} = Settings.put(:install_id, "existing-id")

    assert InstallId.get() == "existing-id"
  end
end
