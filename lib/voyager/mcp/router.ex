defmodule Voyager.MCP.Router do
  @moduledoc """
  Minimal Plug router served by `Voyager.MCP.EndpointManager`.

  Forwards `/mcp` to `Anubis.Server.Transport.StreamableHTTP.Plug`, which
  implements the Streamable HTTP transport for `Voyager.MCP.Server`.
  """

  use Plug.Router

  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1])

  plug :require_loopback_host

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  forward "/mcp",
    to: Anubis.Server.Transport.StreamableHTTP.Plug,
    init_opts: [server: Voyager.MCP.Server]

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp require_loopback_host(conn, _opts) do
    if loopback_host?(conn.host) and origin_allowed?(conn), do: conn, else: forbid(conn)
  end

  defp loopback_host?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  defp loopback_host?(_), do: false

  defp origin_allowed?(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> loopback_host?(URI.parse(origin).host)
    end
  end

  defp forbid(conn) do
    conn
    |> send_resp(403, "Forbidden")
    |> halt()
  end
end
