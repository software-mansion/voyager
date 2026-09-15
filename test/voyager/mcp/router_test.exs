defmodule Voyager.MCP.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Voyager.MCP.Router

  defp guard(origin) do
    conn = conn(:post, "/mcp", "{}")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    Router.reject_cross_origin(conn, [])
  end

  test "request without an Origin header passes" do
    refute guard(nil).halted
  end

  test "loopback Origins pass" do
    for origin <- ["http://localhost:4040", "http://127.0.0.1:4040", "http://[::1]:4040"] do
      refute guard(origin).halted, "expected #{origin} to pass"
    end
  end

  test "a cross-site Origin is forbidden" do
    conn = guard("https://evil.example.com")
    assert conn.status == 403
    assert conn.halted
  end
end
