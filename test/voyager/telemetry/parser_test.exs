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

    test "includes only view name for `:stop` events", %{socket: socket} do
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :stop], %{socket: socket})
      assert result == %{view: "MyApp.SomeLive"}
    end

    test "includes kind and reason for `:exception` events", %{socket: socket} do
      meta = %{socket: socket, kind: :error, reason: %RuntimeError{message: "boom"}}
      result = Parser.parse_metadata([:phoenix, :live_view, :mount, :exception], meta)

      assert result == %{
               view: "MyApp.SomeLive",
               kind: :error,
               reason: "%RuntimeError{message: \"boom\"}"
             }
    end
  end

  describe "parse_metadata/2 for voyager events" do
    test "parse connectors for `node.connect`" do
      result_ssh = Parser.parse_metadata([:voyager, :node, :connect], %{via: :ssh})
      result_direct = Parser.parse_metadata([:voyager, :node, :connect], %{via: :direct})
      assert result_ssh[:via] == :ssh
      assert result_direct[:via] == :direct
    end

    test "returns reason for `node.disconnect`" do
      result =
        Parser.parse_metadata([:voyager, :node, :disconnect], %{reason: :nodedown, foo: :bar})

      assert result == %{reason: :nodedown}
    end

    test "returns empty map for `vm.memory`" do
      result = Parser.parse_metadata([:voyager, :vm, :memory], %{foo: :bar})
      assert result == %{}
    end

    test "returns reason for `mcp.start` and `mcp.stop`" do
      assert Parser.parse_metadata([:voyager, :mcp, :start], %{reason: "boot"}) ==
               %{reason: "boot"}

      assert Parser.parse_metadata([:voyager, :mcp, :stop], %{reason: "crash"}) ==
               %{reason: "crash"}
    end
  end

  describe "parse_metadata/2 for mcp tool call events" do
    test "includes tool name for `tool_call.start` and `tool_call.stop`" do
      assert Parser.parse_metadata([:anubis_mcp, :server, :tool_call, :start], %{
               tool: "node_info"
             }) == %{tool: "node_info"}

      assert Parser.parse_metadata([:anubis_mcp, :server, :tool_call, :stop], %{
               tool: "node_info"
             }) == %{tool: "node_info"}
    end

    test "includes tool name, kind and reason for `tool_call.exception`" do
      meta = %{tool: "node_info", kind: :error, reason: %RuntimeError{message: "boom"}}
      result = Parser.parse_metadata([:anubis_mcp, :server, :tool_call, :exception], meta)

      assert result == %{
               tool: "node_info",
               kind: :error,
               reason: "%RuntimeError{message: \"boom\"}"
             }
    end
  end

  test "parse_metadata/2 returns empty map for unknown events" do
    result = Parser.parse_metadata([:unknown, :event], %{foo: :bar})
    assert result == %{}
  end

  describe "parse_measurements/2 for phoenix live_view events" do
    test "converts native duration to ms" do
      native = System.convert_time_unit(42, :millisecond, :native)

      result =
        Parser.parse_measurements([:phoenix, :live_view, :mount, :stop], %{
          duration: native,
          foo: :bar
        })

      assert result[:duration_ms] == 42
    end

    test "uses nil for nil duration" do
      result =
        Parser.parse_measurements([:phoenix, :live_view, :mount, :stop], %{
          duration: nil,
          kind: :error
        })

      assert result == %{duration_ms: nil}
    end
  end

  describe "parse_measurements/2 for voyager events" do
    test "returns memory measurements for `vm.memory`" do
      measurements = %{
        total: 100,
        processes: 50,
        atom: 10,
        ets: 5,
        binary: 8,
        code: 20,
        system: 7
      }

      other = %{other: 999}

      result = Parser.parse_measurements([:voyager, :vm, :memory], Map.merge(measurements, other))

      assert result == measurements
    end

    test "returns empty map for `node.connect` and `node.disconnect`" do
      assert %{} == Parser.parse_measurements([:voyager, :node, :connect], %{foo: :bar})
      assert %{} == Parser.parse_measurements([:voyager, :node, :disconnect], %{foo: :bar})
    end

    test "returns empty map for `mcp.start` and `mcp.stop`" do
      assert %{} == Parser.parse_measurements([:voyager, :mcp, :start], %{foo: :bar})
      assert %{} == Parser.parse_measurements([:voyager, :mcp, :stop], %{foo: :bar})
    end
  end

  describe "parse_measurements/2 for mcp tool call events" do
    test "returns empty map for `tool_call.start`" do
      result = Parser.parse_measurements([:anubis_mcp, :server, :tool_call, :start], %{foo: :bar})
      assert result == %{}
    end

    test "converts native duration to ms for `tool_call.stop`" do
      native = System.convert_time_unit(42, :millisecond, :native)

      result =
        Parser.parse_measurements([:anubis_mcp, :server, :tool_call, :stop], %{duration: native})

      assert result == %{duration_ms: 42}
    end

    test "converts native duration to ms for `tool_call.exception`" do
      native = System.convert_time_unit(7, :millisecond, :native)

      result =
        Parser.parse_measurements([:anubis_mcp, :server, :tool_call, :exception], %{
          duration: native
        })

      assert result == %{duration_ms: 7}
    end
  end

  test "parse_metadata/2 for unknown events returns empty map" do
    assert %{} == Parser.parse_metadata([:phoenix, :endpoint, :stop], %{foo: "bar"})
  end
end
