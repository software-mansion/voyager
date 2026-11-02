defmodule Voyager.Services.McpClients do
  @moduledoc """
  The AI clients Voyager knows, whether each is installed, and how to point each at Voyager's MCP endpoint.
  Client configs are only ever read, never written.
  """

  @type id :: :claude_code | :codex | :gemini | :cursor
  @type client :: %{
          id: id(),
          name: String.t(),
          command: String.t() | nil,
          link: String.t() | nil,
          config_path: String.t(),
          installed?: boolean(),
          added?: boolean()
        }

  @ids [:claude_code, :codex, :gemini, :cursor]

  @doc "Every client in display order. `config :voyager, :mcp_clients_installed, [id]` overrides detection."
  @spec all(String.t()) :: [client()]
  def all(url) do
    installed =
      Application.get_env(:voyager, :mcp_clients_installed) || Enum.filter(@ids, &detect?/1)

    Enum.map(@ids, fn id ->
      client(id, url)
      |> Map.put(:installed?, id in installed)
      |> Map.put(:added?, added?(id, url))
    end)
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
      config_path: "~/.claude.json",
      command: "claude mcp add --transport http --scope user voyager #{url}",
      link: nil
    }
  end

  defp client(:codex, url) do
    %{
      id: :codex,
      name: "Codex",
      config_path: "~/.codex/config.toml",
      command: "codex mcp add voyager --url #{url}",
      link: nil
    }
  end

  defp client(:gemini, url) do
    %{
      id: :gemini,
      name: "Gemini CLI",
      config_path: "~/.gemini/settings.json",
      command: "gemini mcp add --transport http voyager #{url}",
      link: nil
    }
  end

  defp client(:cursor, url) do
    config = Base.encode64(JSON.encode!(%{url: url}))

    %{
      id: :cursor,
      name: "Cursor",
      config_path: "~/.cursor/mcp.json",
      command: nil,
      link:
        "cursor://anysphere.cursor-deeplink/mcp/install?" <>
          URI.encode_query([name: "voyager", config: config], :rfc3986)
    }
  end

  defp detect?(:claude_code), do: executable_or_dir?("claude", ".claude")

  defp detect?(:codex),
    do: File.dir?("/Applications/Codex.app") or executable_or_dir?("codex", ".codex")

  defp detect?(:gemini), do: executable_or_dir?("gemini", ".gemini")

  defp detect?(:cursor),
    do: File.dir?("/Applications/Cursor.app") or executable_or_dir?("cursor", ".cursor")

  defp executable_or_dir?(executable, dir), do: on_path?(executable) or File.dir?(home_path(dir))

  # Touching a folder macOS guards with a privacy prompt would ask the user for access.
  @protected_dirs ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]

  defp on_path?(executable) do
    protected = Enum.map(@protected_dirs, &home_path/1)

    (System.get_env("PATH") || "")
    |> String.split(":", trim: true)
    |> Enum.reject(fn dir -> Enum.any?(protected, &String.starts_with?(Path.expand(dir), &1)) end)
    |> Enum.any?(&File.regular?(Path.join(&1, executable)))
  end

  defp added?(:claude_code, url) do
    config = read_json(".claude.json")
    projects = Map.values(config["projects"] || %{})
    Enum.any?([config | projects], &servers_with_url?(&1["mcpServers"], url))
  end

  defp added?(:cursor, url),
    do: servers_with_url?(read_json(".cursor/mcp.json")["mcpServers"], url)

  defp added?(:gemini, url),
    do: servers_with_url?(read_json(".gemini/settings.json")["mcpServers"], url)

  defp added?(:codex, url) do
    case File.read(home_path(".codex/config.toml")) do
      {:ok, toml} -> String.contains?(toml, ~s|url = "#{url}"|)
      {:error, _reason} -> false
    end
  end

  defp servers_with_url?(servers, url) when is_map(servers) do
    Enum.any?(Map.values(servers), fn server ->
      is_map(server) and url in [server["url"], server["httpUrl"], server["serverUrl"]]
    end)
  end

  defp servers_with_url?(_servers, _url), do: false

  defp read_json(relative) do
    with {:ok, contents} <- File.read(home_path(relative)),
         {:ok, %{} = config} <- JSON.decode(contents) do
      config
    else
      _ -> %{}
    end
  end

  defp home_path(relative),
    do:
      Path.join(Application.get_env(:voyager, :mcp_clients_home) || System.user_home!(), relative)
end
