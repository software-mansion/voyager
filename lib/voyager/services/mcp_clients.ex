defmodule Voyager.Services.McpClients do
  @moduledoc """
  Install links and setup commands that point AI clients at Voyager's MCP endpoint.
  Nothing here writes to disk: install links hand the config to the client app, which asks the user to confirm.
  """

  @type app :: %{id: String.t(), name: String.t(), link: String.t()}
  @type command :: %{id: String.t(), name: String.t(), command: String.t()}

  @spec apps(String.t()) :: [app()]
  def apps(url) do
    vscode_config = encode(JSON.encode!(%{name: "voyager", type: "http", url: url}))

    [
      %{
        id: "cursor",
        name: "Cursor",
        link:
          "cursor://anysphere.cursor-deeplink/mcp/install?" <>
            query(name: "voyager", config: base64_json(%{url: url}))
      },
      %{id: "vscode", name: "VS Code", link: "vscode:mcp/install?" <> vscode_config},
      %{
        id: "vscode_insiders",
        name: "VS Code Insiders",
        link: "vscode-insiders:mcp/install?" <> vscode_config
      },
      %{
        id: "lm_studio",
        name: "LM Studio",
        link: "lmstudio://add_mcp?" <> query(name: "voyager", config: base64_json(%{url: url}))
      },
      %{
        id: "goose",
        name: "Goose",
        link:
          "goose://extension?" <>
            query(
              url: url,
              type: "streamable_http",
              id: "voyager",
              name: "Voyager",
              description: "Inspect the connected BEAM node",
              timeout: 300
            )
      },
      %{
        id: "kiro",
        name: "Kiro",
        link:
          "https://kiro.dev/launch/mcp/add?" <>
            query(
              name: "voyager",
              config: JSON.encode!(%{url: url, disabled: false, autoApprove: []})
            )
      }
    ]
  end

  @spec commands(String.t()) :: [command()]
  def commands(url) do
    [
      %{
        id: "claude_code",
        name: "Claude Code",
        command: "claude mcp add --transport http --scope user voyager #{url}"
      },
      %{id: "codex", name: "Codex", command: "codex mcp add voyager --url #{url}"},
      %{
        id: "gemini",
        name: "Gemini CLI",
        command: "gemini mcp add --transport http voyager #{url}"
      },
      %{
        id: "windsurf",
        name: "Windsurf · ~/.codeium/windsurf/mcp_config.json",
        command: JSON.encode!(%{mcpServers: %{voyager: %{serverUrl: url}}})
      }
    ]
  end

  defp base64_json(config), do: Base.encode64(JSON.encode!(config))

  defp query(params), do: URI.encode_query(params, :rfc3986)

  defp encode(string), do: URI.encode(string, &URI.char_unreserved?/1)
end
