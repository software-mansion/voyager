defmodule Voyager.Services.McpClients.Cursor do
  @moduledoc false
  @behaviour Voyager.Services.McpClients

  alias Voyager.Services.McpClients
  alias Voyager.Services.McpClients.JsonConfig

  @impl true
  def detect?, do: File.dir?(Path.join(McpClients.home(), ".cursor"))

  @impl true
  def status(url), do: JsonConfig.status(path(), entry(url))

  @impl true
  def install(url), do: JsonConfig.install(path(), entry(url))

  @impl true
  def remove, do: JsonConfig.remove(path())

  defp path, do: Path.join(McpClients.home(), ".cursor/mcp.json")

  defp entry(url), do: %{"url" => url}
end
