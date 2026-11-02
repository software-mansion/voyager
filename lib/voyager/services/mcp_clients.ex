defmodule Voyager.Services.McpClients do
  @moduledoc """
  The AI clients installed on this machine and how to point each at Voyager's MCP endpoint.
  Nothing here writes to disk.
  """

  @type id :: :claude_code | :codex | :gemini | :cursor
  @type client :: %{
          id: id(),
          name: String.t(),
          subtitle: String.t(),
          icon: String.t(),
          command: String.t() | nil,
          link: String.t() | nil
        }

  @ids [:claude_code, :codex, :gemini, :cursor]

  @doc "Installed clients in display order. `config :voyager, :mcp_clients_installed, [id]` overrides detection."
  @spec installed(String.t()) :: [client()]
  def installed(url) do
    detected =
      Application.get_env(:voyager, :mcp_clients_installed) || Enum.filter(@ids, &detect?/1)

    for id <- @ids, id in detected, do: client(id, url)
  end

  @doc "The row a connected client belongs to, from the name in its `clientInfo`."
  @spec match(String.t()) :: id() | nil
  def match(name) do
    name = String.downcase(name)

    cond do
      String.starts_with?(name, "claude-code") -> :claude_code
      String.contains?(name, "codex") -> :codex
      String.contains?(name, "gemini") -> :gemini
      String.contains?(name, "cursor") -> :cursor
      true -> nil
    end
  end

  @spec setup_prompt(String.t()) :: String.t()
  def setup_prompt(url) do
    "Add an MCP server named \"voyager\" to your MCP config. " <>
      "It uses the Streamable HTTP transport at #{url} and needs no authentication."
  end

  defp client(:claude_code, url) do
    %{
      id: :claude_code,
      name: "Claude Code",
      subtitle: "Also covers the Code tab in the Claude app",
      icon: "icon-brand-claude",
      command: "claude mcp add --transport http --scope user voyager #{url}",
      link: nil
    }
  end

  defp client(:codex, url) do
    %{
      id: :codex,
      name: "Codex",
      subtitle: "CLI, IDE extension and app",
      icon: "icon-brand-openai",
      command: "codex mcp add voyager --url #{url}",
      link: nil
    }
  end

  defp client(:gemini, url) do
    %{
      id: :gemini,
      name: "Gemini CLI",
      subtitle: "Google's terminal agent",
      icon: "icon-brand-gemini",
      command: "gemini mcp add --transport http voyager #{url}",
      link: nil
    }
  end

  defp client(:cursor, url) do
    config = Base.encode64(JSON.encode!(%{url: url}))

    %{
      id: :cursor,
      name: "Cursor",
      subtitle: "Opens Cursor to confirm the install",
      icon: "icon-brand-cursor",
      command: nil,
      link:
        "cursor://anysphere.cursor-deeplink/mcp/install?" <>
          URI.encode_query([name: "voyager", config: config], :rfc3986)
    }
  end

  defp detect?(:claude_code), do: executable_or_dir?("claude", ".claude")
  defp detect?(:codex), do: executable_or_dir?("codex", ".codex")
  defp detect?(:gemini), do: executable_or_dir?("gemini", ".gemini")

  defp detect?(:cursor),
    do: File.dir?("/Applications/Cursor.app") or executable_or_dir?("cursor", ".cursor")

  defp executable_or_dir?(executable, dir) do
    System.find_executable(executable) != nil or File.dir?(Path.join(System.user_home!(), dir))
  end
end
