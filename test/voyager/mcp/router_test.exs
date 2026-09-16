defmodule Voyager.MCP.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Voyager.MCP.Router

  @opts Router.init([])

  defp call(method, url, origin) do
    conn = conn(method, url, "{}") |> put_req_header("content-type", "application/json")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    Router.call(conn, @opts)
  end

  test "a loopback Host passes the guard" do
    for host <- ["http://127.0.0.1:4040", "http://localhost:4040", "http://LOCALHOST:4040"] do
      assert call(:post, host <> "/unknown", nil).status == 404, "expected #{host} to pass"
    end
  end

  test "IPv6 loopback Hosts pass the guard, bracketed as Bandit sets it and bare" do
    for host <- ["[::1]", "::1"] do
      assert Router.call(%{conn(:post, "/unknown") | host: host}, @opts).status == 404
    end
  end

  test "a loopback Host passes the guard on GET" do
    assert Router.call(conn(:get, "http://127.0.0.1:4040/unknown"), @opts).status == 404
  end

  test "lookalike Hosts, an empty Host and a null Origin are forbidden" do
    for {host, origin} <- [
          {"localhost.", nil},
          {"127.0.0.2", nil},
          {"", nil},
          {"127.0.0.1", "null"}
        ] do
      conn = %{conn(:post, "/mcp") | host: host}
      conn = if origin, do: put_req_header(conn, "origin", origin), else: conn

      assert Router.call(conn, @opts).status == 403,
             "expected #{inspect(host)}/#{inspect(origin)} to be forbidden"
    end
  end

  test "a non-loopback Host is forbidden even without an Origin" do
    conn = call(:post, "http://rebind.fella.top:4040/mcp", nil)
    assert conn.status == 403
    assert conn.halted
  end

  test "a non-loopback Host is forbidden on GET (SSE stream)" do
    conn = Router.call(conn(:get, "http://rebind.fella.top:4040/mcp"), @opts)
    assert conn.status == 403
    assert conn.halted
  end

  test "a loopback Host with a cross-site Origin is forbidden" do
    conn = call(:post, "http://127.0.0.1:4040/mcp", "https://evil.example.com")
    assert conn.status == 403
    assert conn.halted
  end

  test "a loopback Host with a loopback Origin passes" do
    conn = call(:post, "http://127.0.0.1:4040/unknown", "http://localhost:4040")
    assert conn.status == 404
  end
end
