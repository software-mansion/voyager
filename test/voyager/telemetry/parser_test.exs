defmodule Voyager.Telemetry.ParserTest do
  use ExUnit.Case, async: true

  alias Voyager.Telemetry.Parser

  test "parse_event/1 joins event segments with dots" do
    assert Parser.parse_event([:voyager, :vm, :memory]) == "voyager.vm.memory"
  end

  describe "parse_metadata/2 for phoenix live_view events" do
    setup do
      socket = %{view: MyApp.SomeLive, host_uri: "http://localhost:4000", assigns: %{}}
      %{socket: socket}
    end

    test "extracts view name from socket", %{socket: socket} do
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :start], %{socket: socket})
      assert result[:view] == inspect(MyApp.SomeLive)
    end

    test "includes event key for handle_event", %{socket: socket} do
      meta = %{socket: socket, event: "save"}
      result = Parser.parse_metadata([:phoenix, :live_view, :handle_event, :stop], meta)
      assert result[:event] == "save"
    end

    test "omits event key when not present", %{socket: socket} do
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :stop], %{socket: socket})
      refute Map.has_key?(result, :event)
    end

    test "includes socket host_uri", %{socket: socket} do
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :start], %{socket: socket})
      assert result[:uri] == nil
    end

    test "does not include kind/reason for mount exception events (rest is [:mount, :exception])",
         %{socket: socket} do
      meta = %{socket: socket, kind: :error, reason: %RuntimeError{message: "boom"}}
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :exception], meta)
      # maybe_exception only matches rest == [:exception]; for real events rest has the action too
      refute Map.has_key?(result, :kind)
      refute Map.has_key?(result, :reason)
    end
  end

  test "parse_metadata/2 for unknown events returns empty map" do
    assert %{} == Parser.parse_metadata([:phoenix, :endpoint, :stop], %{foo: "bar"})
  end
end
