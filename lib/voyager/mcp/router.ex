defmodule Voyager.MCP.Router do
  @moduledoc """
  Minimal Plug router served by `Voyager.MCP.EndpointManager`.

  Forwards `/mcp` to `Anubis.Server.Transport.StreamableHTTP.Plug`, which
  implements the Streamable HTTP transport for `Voyager.MCP.Server`.
  """

  use Plug.Router

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason

  plug :reject_cross_origin
  plug :match
  plug :dispatch

  # Anubis passes `:subscriber_metadata` to the `forward` without using MFA format which results in errors.
  forward "/mcp",
    to: Anubis.Server.Transport.StreamableHTTP.Plug,
    init_opts: [
      server: Voyager.MCP.Server,
      subscriber_metadata: &__MODULE__.subscriber_metadata/1
    ]

  match _ do
    send_resp(conn, 404, "Not found")
  end

  @doc false
  def reject_cross_origin(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> conn
      [origin | _] -> if loopback_origin?(origin), do: conn, else: forbid(conn)
    end
  end

  defp loopback_origin?(origin) do
    URI.parse(origin).host in @loopback_hosts
  end

  defp forbid(conn) do
    conn
    |> send_resp(403, "Forbidden")
    |> halt()
  end

  @doc false
  def subscriber_metadata(_conn), do: %{}
end
