defmodule Voyager.MCP.Router do
  @moduledoc """
  Minimal Plug router served by `Voyager.MCP.EndpointManager`.

  Forwards `/mcp` to `Anubis.Server.Transport.StreamableHTTP.Plug`, which
  implements the Streamable HTTP transport for `Voyager.MCP.Server`.
  """

  use Plug.Router

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
end
