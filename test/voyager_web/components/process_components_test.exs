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
    test "a quick fetch reads as ordinary" do
      assert summary(900) =~ "text-base-content"
    end

    test "over a second warns" do
      assert summary(1_001) =~ "text-warning"
    end

    test "over five seconds is an error" do
      assert summary(5_001) =~ "text-error"
    end

    test "the boundaries themselves stay in the lower band" do
      assert summary(1_000) =~ "text-base-content"
      assert summary(5_000) =~ "text-warning"
    end

    test "omits the round trip when there is none" do
      refute summary(nil) =~ "ms"
    end
  end
end
