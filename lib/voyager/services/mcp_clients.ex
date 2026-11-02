defmodule Voyager.Services.McpClients do
  @moduledoc """
  Detects local AI clients and writes Voyager's MCP server entry into their
  user-level config files. Only the `voyager` entry is ever touched, and the
  previous file is copied to `<file>.bak` before every write.
  """

  alias Voyager.Services.McpClients.ClaudeCode
  alias Voyager.Services.McpClients.Codex
  alias Voyager.Services.McpClients.Cursor
  alias Voyager.Services.McpClients.Gemini

  @type status :: :configured | :outdated | :missing
  @type client :: %{id: String.t(), name: String.t(), adapter: module()}

  @callback detect?() :: boolean()
  @callback status(url :: String.t()) :: status()
  @callback install(url :: String.t()) :: :ok | {:error, term()}
  @callback remove() :: :ok | {:error, term()}

  @clients [
    %{id: "claude_code", name: "Claude Code", adapter: ClaudeCode},
    %{id: "cursor", name: "Cursor", adapter: Cursor},
    %{id: "gemini", name: "Gemini CLI", adapter: Gemini},
    %{id: "codex", name: "Codex", adapter: Codex}
  ]

  @spec all() :: [client()]
  def all, do: @clients

  @doc "Every client with its `:status` for `url`, or `:not_detected` when it is not installed."
  @spec statuses(String.t()) :: [%{status: status() | :not_detected}]
  def statuses(url) do
    Enum.map(@clients, fn client ->
      status = if client.adapter.detect?(), do: client.adapter.status(url), else: :not_detected
      Map.put(client, :status, status)
    end)
  end

  @spec install(String.t(), String.t()) :: :ok | {:error, term()}
  def install(id, url) do
    with {:ok, client} <- fetch(id), do: client.adapter.install(url)
  end

  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(id) do
    with {:ok, client} <- fetch(id), do: client.adapter.remove()
  end

  @spec home() :: Path.t()
  def home, do: Application.get_env(:voyager, :mcp_clients_home) || System.user_home!()

  @spec cli_command(String.t(), String.t()) :: String.t() | nil
  def cli_command("claude_code", url),
    do: "claude mcp add --transport http --scope user voyager #{url}"

  def cli_command("codex", url), do: "codex mcp add voyager --url #{url}"
  def cli_command("gemini", url), do: "gemini mcp add --transport http voyager #{url}"
  def cli_command(_id, _url), do: nil

  @spec cursor_deeplink(String.t()) :: String.t()
  def cursor_deeplink(url) do
    config = Base.encode64(JSON.encode!(%{"url" => url}))

    "cursor://anysphere.cursor-deeplink/mcp/install?" <>
      URI.encode_query(name: "voyager", config: config)
  end

  @doc false
  @spec backup(Path.t()) :: :ok | {:error, term()}
  def backup(path) do
    if File.exists?(path), do: File.cp(path, path <> ".bak"), else: :ok
  end

  defp fetch(id) do
    case Enum.find(@clients, &(&1.id == id)) do
      nil -> {:error, :unknown_client}
      client -> {:ok, client}
    end
  end
end
