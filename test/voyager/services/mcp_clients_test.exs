defmodule Voyager.Services.McpClientsTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.McpClients

  @url "http://127.0.0.1:4040/mcp"

  setup do
    on_exit(fn -> Application.delete_env(:voyager, :mcp_clients_installed) end)
  end

  test "lists only installed clients, in display order" do
    Application.put_env(:voyager, :mcp_clients_installed, [:cursor, :claude_code])

    assert Enum.map(McpClients.installed(@url), & &1.id) == [:claude_code, :cursor]
  end

  test "only cursor has an install link, carrying a base64 url config" do
    Application.put_env(:voyager, :mcp_clients_installed, [:claude_code, :codex, :gemini, :cursor])

    clients = Map.new(McpClients.installed(@url), &{&1.id, &1})

    assert clients |> Map.values() |> Enum.filter(& &1.link) |> Enum.map(& &1.id) == [:cursor]
    assert clients.codex.command == "codex mcp add voyager --url #{@url}"

    %URI{scheme: "cursor", query: query} = URI.parse(clients.cursor.link)
    assert %{"name" => "voyager", "config" => config} = URI.decode_query(query)
    assert config |> Base.decode64!() |> JSON.decode!() == %{"url" => @url}
  end

  test "matches reported client names to rows" do
    assert McpClients.match("claude-code") == :claude_code
    assert McpClients.match("codex-mcp-client") == :codex
    assert McpClients.match("gemini-cli-mcp-client") == :gemini
    assert McpClients.match("cursor-vscode") == :cursor
    assert McpClients.match("zed") == nil
  end
end
