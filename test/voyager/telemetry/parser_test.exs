defmodule Voyager.Telemetry.ParserTest do
  @moduledoc false
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

    test "doesn't include socket host_uri", %{socket: socket} do
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :stop], %{socket: socket})
      assert result[:uri] == nil
    end

    test "includes kind and reason for exception events", %{socket: socket} do
      meta = %{socket: socket, kind: :error, reason: %RuntimeError{message: "boom"}}
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :exception], meta)
      assert result[:kind] == :error
      assert result[:reason] == "%RuntimeError{message: \"boom\"}"
    end
  end

  test "parse_metadata/2 for unknown events returns empty map" do
    assert %{} == Parser.parse_metadata([:phoenix, :endpoint, :stop], %{foo: "bar"})
  end
end
