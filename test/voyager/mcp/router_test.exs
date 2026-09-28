defmodule Voyager.MCP.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Voyager.MCP.Router

  @opts Router.init([])

  defp call(path, origin) do
    conn = conn(:post, path, "{}") |> put_req_header("content-type", "application/json")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    Router.call(conn, @opts)
  end

  test "request without an Origin header passes the guard" do
    assert call("/unknown", nil).status == 404
  end

  test "loopback Origins pass the guard" do
    for origin <- ["http://localhost:4040", "http://127.0.0.1:4040", "http://[::1]:4040"] do
      assert call("/unknown", origin).status == 404, "expected #{origin} to pass"
    end
  end

  test "a cross-site Origin is forbidden before reaching /mcp" do
    conn = call("/mcp", "https://evil.example.com")
    assert conn.status == 403
    assert conn.halted
  end
end
