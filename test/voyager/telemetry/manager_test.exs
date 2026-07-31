defmodule Voyager.Telemetry.ManagerTest do
  use Voyager.DataCase, async: false

  alias Voyager.Settings
  alias Voyager.Telemetry
  alias Voyager.Telemetry.Manager

  defmodule SpyHandler do
    @moduledoc false
    @behaviour Voyager.Telemetry.Handler

    @impl true
    def handle_event(event, measurements, metadata, %{parent: parent}) do
      send(parent, {:handled, event, measurements, metadata})
      :ok
    end
  end

  setup do
    on_exit(fn ->
      Application.put_env(:voyager, :terms_accepted, true)
      Manager.set_enabled(true)
    end)

    :ok
  end

  describe "enabled?/0 and set_enabled/1" do
    test "defaults to enabled when terms are accepted" do
      assert Telemetry.enabled?()
    end

    test "persists the choice and updates the cache" do
      assert {:ok, _setting} = Telemetry.set_enabled(false)
      refute Telemetry.enabled?()
      assert Settings.get(:telemetry_enabled) == false

      assert {:ok, _setting} = Telemetry.set_enabled(true)
      assert Telemetry.enabled?()
    end

    test "stays disabled until terms are accepted" do
      Application.delete_env(:voyager, :terms_accepted)
      assert {:ok, _setting} = Telemetry.set_enabled(true)

      refute Telemetry.enabled?()

      assert {:ok, _setting} = Telemetry.accept_terms()
      assert Telemetry.enabled?()
    end

    test "returns {:error, :locked} when controlled by application config" do
      Application.put_env(:voyager, :telemetry_enabled, false)
      on_exit(fn -> Application.delete_env(:voyager, :telemetry_enabled) end)

      assert {:error, :locked} = Telemetry.set_enabled(true)
    end
  end

  describe "handle_event/4" do
    test "forwards the event to the handler module when enabled" do
      Manager.set_enabled(true)
      config = %{handler_module: SpyHandler, handler_config: %{parent: self()}}

      assert :ok = Manager.handle_event([:voyager, :node, :connect], %{a: 1}, %{b: 2}, config)
      assert_received {:handled, [:voyager, :node, :connect], %{a: 1}, %{b: 2}}
    end

    test "skips the handler module when disabled" do
      Manager.set_enabled(false)
      config = %{handler_module: SpyHandler, handler_config: %{parent: self()}}

      assert :ok = Manager.handle_event([:voyager, :node, :connect], %{}, %{}, config)
      refute_received {:handled, _event, _measurements, _metadata}
    end

    test "skips the handler module before terms are accepted" do
      Application.delete_env(:voyager, :terms_accepted)
      Manager.set_enabled(true)
      config = %{handler_module: SpyHandler, handler_config: %{parent: self()}}

      assert :ok = Manager.handle_event([:voyager, :node, :connect], %{}, %{}, config)
      refute_received {:handled, _event, _measurements, _metadata}
    end
  end
end
