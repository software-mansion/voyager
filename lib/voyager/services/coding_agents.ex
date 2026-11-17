defmodule Voyager.Services.CodingAgents do
  @moduledoc """
  The coding agents Voyager can add its MCP server to. An agent counts as detected when one of its
  folders exists in the home directory, and Voyager is added to its global config file.
  """

  alias Voyager.Services.McpConfigFile

  @type id ::
          :cursor
          | :claude_code
          | :vscode
          | :copilot
          | :zed
          | :antigravity
          | :codex
          | :opencode
  @type status :: :added | :outdated | :not_added | :manual
  @type agent :: %{
          id: id(),
          name: String.t(),
          path: String.t(),
          detected?: boolean(),
          status: status(),
          removable?: boolean(),
          snippet: String.t()
        }

  @vscode_user if match?({:unix, :darwin}, :os.type()),
                 do: "Library/Application Support/Code/User",
                 else: ".config/Code/User"

  # `:url` in an entry stands for Voyager's MCP URL; `path` lists candidates, the first that exists wins.
  @agents [
    %{
      id: :cursor,
      name: "Cursor",
      clients: ["cursor"],
      detect: [".cursor"],
      path: [".cursor/mcp.json"],
      format: :json,
      key: ["mcpServers"],
      entry: %{"url" => :url}
    },
    %{
      id: :claude_code,
      name: "Claude Code",
      clients: ["claude-code", "claude code"],
      detect: [".claude", ".claude.json"],
      path: [".claude.json"],
      format: :json,
      key: ["mcpServers"],
      entry: %{"type" => "http", "url" => :url}
    },
    %{
      id: :vscode,
      name: "VS Code / Copilot",
      clients: ["visual studio code", "vscode"],
      detect: [".vscode", @vscode_user],
      path: ["#{@vscode_user}/mcp.json"],
      format: :json,
      key: ["servers"],
      entry: %{"type" => "http", "url" => :url}
    },
    %{
      id: :copilot,
      name: "Copilot CLI",
      clients: ["copilot"],
      detect: [".copilot"],
      path: [".copilot/mcp-config.json"],
      format: :json,
      key: ["mcpServers"],
      entry: %{"type" => "http", "url" => :url, "tools" => ["*"]}
    },
    %{
      id: :zed,
      name: "Zed",
      clients: ["zed"],
      detect: [".config/zed"],
      path: [".config/zed/settings.json"],
      format: :json,
      key: ["context_servers"],
      entry: %{"url" => :url}
    },
    %{
      id: :antigravity,
      name: "Antigravity",
      clients: ["antigravity"],
      detect: [".gemini/config", ".gemini/antigravity"],
      path: [".gemini/config/mcp_config.json"],
      format: :json,
      key: ["mcpServers"],
      entry: %{"serverUrl" => :url}
    },
    %{
      id: :codex,
      name: "Codex",
      clients: ["codex"],
      detect: [".codex"],
      path: [".codex/config.toml"],
      format: :toml,
      key: ["mcp_servers"],
      entry: %{"url" => :url}
    },
    %{
      id: :opencode,
      name: "opencode",
      clients: ["opencode"],
      detect: [".config/opencode", ".local/share/opencode"],
      path: [".config/opencode/opencode.jsonc", ".config/opencode/opencode.json"],
      format: :json,
      key: ["mcp"],
      entry: %{"type" => "remote", "url" => :url, "enabled" => true}
    }
  ]

  @doc """
  Every agent with whether it is detected and whether its config already points at `url`.
  Empty when there is no home directory.
  """
  @spec scan(String.t()) :: [agent()]
  def scan(url), do: scan(url, home())

  defp scan(_url, nil), do: []

  defp scan(url, home) do
    Enum.map(@agents, fn agent ->
      path = config_path(agent, home)
      {status, removable?} = config_state(agent, path, url)

      %{
        id: agent.id,
        name: agent.name,
        path: "~/" <> Path.relative_to(path, home),
        detected?: Enum.any?(agent.detect, &File.exists?(Path.join(home, &1))),
        status: status,
        removable?: removable?,
        snippet: snippet(agent, url)
      }
    end)
  end

  @doc "Points the agent's global config at `url`. Fails when that file cannot be parsed."
  @spec install(id(), String.t()) :: :ok | {:error, term()}
  def install(id, url) do
    agent = Enum.find(@agents, &(&1.id == id))

    with {:ok, home} <- fetch_home() do
      McpConfigFile.put_server(
        config_path(agent, home),
        agent.format,
        agent.key,
        entry(agent, url)
      )
    end
  end

  @doc "Removes the `voyager` entry from the agent's global config."
  @spec remove(id()) :: :ok | {:error, term()}
  def remove(id) do
    agent = Enum.find(@agents, &(&1.id == id))

    with {:ok, home} <- fetch_home() do
      McpConfigFile.delete_server(config_path(agent, home), agent.format, agent.key)
    end
  end

  @spec fetch(String.t()) :: {:ok, id()} | :error
  def fetch(id) do
    case Enum.find(@agents, &(Atom.to_string(&1.id) == id)) do
      nil -> :error
      agent -> {:ok, agent.id}
    end
  end

  @doc "The agent an MCP client belongs to, from the name in its `clientInfo`."
  @spec match(String.t()) :: id() | nil
  def match(client_name) do
    client_name = String.downcase(client_name)

    Enum.find_value(@agents, fn agent ->
      if Enum.any?(agent.clients, &String.contains?(client_name, &1)), do: agent.id
    end)
  end

  @spec setup_prompt(String.t()) :: String.t()
  def setup_prompt(url) do
    "Add an MCP server named \"voyager\" to your global MCP configuration. " <>
      "It uses the Streamable HTTP transport at #{url} and needs no authentication."
  end

  defp config_state(agent, path, url) do
    case McpConfigFile.servers(path, agent.format, agent.key) do
      {:ok, servers} ->
        named? = Map.has_key?(servers, McpConfigFile.server_name())

        status =
          cond do
            Enum.any?(servers, fn {_name, entry} -> active_at?(entry, url) end) -> :added
            named? -> :outdated
            true -> :not_added
          end

        {status, named?}

      {:error, _reason} ->
        {:manual, false}
    end
  end

  defp active_at?(entry, url), do: entry["enabled"] != false and url in Map.values(entry)

  defp snippet(%{format: :json} = agent, url) do
    agent.key
    |> Kernel.++([McpConfigFile.server_name()])
    |> List.foldr(entry(agent, url), &%{&1 => &2})
    |> Jason.encode!(pretty: true)
  end

  defp snippet(%{format: :toml, key: [table]} = agent, url) do
    McpConfigFile.toml_table("#{table}.#{McpConfigFile.server_name()}", entry(agent, url))
  end

  defp entry(agent, url) do
    Map.new(agent.entry, fn
      {key, :url} -> {key, url}
      pair -> pair
    end)
  end

  defp config_path(agent, home) do
    paths = Enum.map(agent.path, &Path.join(home, &1))
    Enum.find(paths, List.last(paths), &File.exists?/1)
  end

  defp fetch_home do
    case home() do
      nil -> {:error, :no_home}
      home -> {:ok, home}
    end
  end

  defp home, do: Application.get_env(:voyager, :coding_agents_home) || System.user_home()
end
