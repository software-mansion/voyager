defmodule Voyager.Telemetry.InstallIdTest do
  use Voyager.DataCase, async: false

  import Voyager.TestUtils, only: [isolate_persistent_term: 1]

  alias Voyager.Settings
  alias Voyager.Telemetry.InstallId

  setup do
    isolate_persistent_term({InstallId, :install_id})
    InstallId.clear_cache()
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
