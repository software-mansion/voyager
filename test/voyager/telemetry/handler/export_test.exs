defmodule Voyager.Telemetry.Handler.ExportTest do
  use Voyager.DataCase, async: false

  alias Voyager.Telemetry.Handler.Export
  alias Voyager.Telemetry.InstallId

  setup do
    InstallId.clear_cache()
    on_exit(&InstallId.clear_cache/0)
    :ok
  end

  test "build_payload/3 includes the anonymous install id in metadata" do
    install_id = InstallId.get()

    payload = Export.build_payload([:voyager, :node, :connect], %{}, %{foo: :bar})

    assert payload.event == "voyager.node.connect"
    assert payload.measurements == %{}
    assert payload.metadata == %{install_id: install_id}
    assert is_integer(payload.ts)
  end

  test "build_payload/3 keeps install_id when event metadata is present" do
    install_id = InstallId.get()

    payload =
      Export.build_payload([:voyager, :node, :disconnect], %{}, %{reason: :nodedown, foo: :bar})

    assert payload.metadata == %{reason: :nodedown, install_id: install_id}
  end
end
