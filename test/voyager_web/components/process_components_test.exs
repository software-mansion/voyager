defmodule VoyagerWeb.Components.ProcessComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.Components.ProcessComponents

  defp summary(round_trip_ms) do
    render_component(&ProcessComponents.scan_summary/1,
      id: "s",
      shown: 1,
      scanned: 2,
      round_trip_ms: round_trip_ms
    )
  end

  describe "scan_summary/1" do
    test "colours the round trip by how slow the fetch was" do
      bands = [
        {900, "text-base-content"},
        {1_000, "text-base-content"},
        {1_001, "text-warning"},
        {10_000, "text-error"}
      ]

      for {ms, class} <- bands, do: assert(summary(ms) =~ class)
    end

    test "omits the round trip when there is none" do
      refute summary(nil) =~ "ms"
    end
  end
end
