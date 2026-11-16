defmodule Voyager.MCP.ToolCallTrackingTest do
  use Voyager.MCPCase

  alias Voyager.Services.McpAgents

  setup do
    previous_state = :sys.get_state(McpAgents)
    on_exit(fn -> :sys.replace_state(McpAgents, fn _ -> previous_state end) end)
    :sys.replace_state(McpAgents, &%{&1 | calls: %{}})
    McpAgents.refresh()
    _ = :sys.get_state(McpAgents)
    :ok
  end

  test "a real tools/call marks its client as recently used", %{mcp_port: port} do
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
            clientInfo: %{name: "claude-code", version: "2.1.0"}
          }
        }
      )

    [session_id] = Req.Response.get_header(init_resp, "mcp-session-id")
    session_headers = headers ++ [{"mcp-session-id", session_id}]

    Req.post!(url,
      headers: session_headers,
      json: %{jsonrpc: "2.0", method: "notifications/initialized"}
    )

    assert McpAgents.get().recent == []

    Req.post!(url,
      headers: session_headers,
      json: %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "node_info", arguments: %{}}
      }
    )

    _ = :sys.get_state(McpAgents)

    assert [%{name: "claude-code", version: "2.1.0", agent_id: :claude_code}] =
             McpAgents.get().recent
  end
end
