defmodule Voyager.MCP.TelemetryVerificationTest do
  @moduledoc false
  # Regression test: the event names in Voyager.Telemetry.Events.events(:mcp)
  # must match what the anubis_mcp dependency actually emits during a real
  # tools/call over the streamable HTTP transport.
  use Voyager.MCPCase

  alias Voyager.Telemetry.Events

  test "subscribed MCP events fire on a real tools/call", %{mcp_port: port} do
    parent = self()
    handler_id = "mcp-tool-call-verify-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      Events.events(:mcp),
      fn event, _measurements, metadata, _config ->
        send(parent, {:telemetry, event, Map.take(metadata, [:tool])})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    url = "http://127.0.0.1:#{port}/mcp"
    headers = [{"accept", "application/json, text/event-stream"}]

    init_resp =
      Req.post!(url,
        headers: headers,
        json: %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-03-26",
            capabilities: %{},
            clientInfo: %{name: "telemetry-verify", version: "0.0.0"}
          }
        }
      )

    assert init_resp.status == 200
    [session_id] = Req.Response.get_header(init_resp, "mcp-session-id")
    session_headers = headers ++ [{"mcp-session-id", session_id}]

    Req.post!(url,
      headers: session_headers,
      json: %{jsonrpc: "2.0", method: "notifications/initialized"}
    )

    call_resp =
      Req.post!(url,
        headers: session_headers,
        json: %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{name: "node_info", arguments: %{}}
        }
      )

    assert call_resp.status == 200

    assert_receive {:telemetry, [:anubis_mcp, :server, :tool_call, :start], %{tool: "node_info"}},
                   1_000

    assert_receive {:telemetry, [:anubis_mcp, :server, :tool_call, :stop], %{tool: "node_info"}},
                   1_000
  end
end
