defmodule Voyager.Telemetry.Handler.ExportTest do
  use Voyager.DataCase, async: false

  import Voyager.TestUtils, only: [isolate_persistent_term: 1, isolate_persistent_term: 2]

  alias Voyager.Telemetry.Handler.Export
  alias Voyager.Telemetry.InstallId

  setup do
    isolate_persistent_term({InstallId, :install_id})
    isolate_persistent_term(:connected_via, nil)
    InstallId.clear_cache()
    :ok
  end

  test "build_payload/3 includes additional metadata" do
    install_id = InstallId.get()

    payload =
      Export.build_payload([:voyager, :node, :connect], %{}, %{connected_via: :direct, foo: :bar})

    assert payload.event == "voyager.node.connect"
    assert payload.measurements == %{}

    assert payload.metadata == %{
             connected_via: :direct,
             install_id: install_id,
             vsn: Voyager.version(),
             os_type: :os.type()
           }

    assert is_integer(payload.ts)
  end

  test "build_payload/3 keeps additional metadata when event metadata is present" do
    install_id = InstallId.get()

    payload =
      Export.build_payload([:voyager, :node, :disconnect], %{}, %{reason: :nodedown, foo: :bar})

    assert payload.metadata == %{
             reason: :nodedown,
             connected_via: nil,
             install_id: install_id,
             vsn: Voyager.version(),
             os_type: :os.type()
           }
  end

  test "build_payload/3 includes connector and inspected reason for connect_failed" do
    install_id = InstallId.get()

    payload =
      Export.build_payload([:voyager, :node, :connect_failed], %{}, %{
        connected_via: :ssh,
        reason: :connection_failed
      })

    assert payload.event == "voyager.node.connect_failed"
    assert payload.measurements == %{}

    assert payload.metadata == %{
             connected_via: :ssh,
             reason: "connection_failed",
             install_id: install_id,
             vsn: Voyager.version(),
             os_type: :os.type()
           }
  end
end
