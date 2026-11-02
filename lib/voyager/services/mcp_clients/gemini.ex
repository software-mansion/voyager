defmodule Voyager.Services.McpClients.Gemini do
  @moduledoc false
  @behaviour Voyager.Services.McpClients

  alias Voyager.Services.McpClients
  alias Voyager.Services.McpClients.JsonConfig

  @impl true
  def detect?, do: File.dir?(Path.join(McpClients.home(), ".gemini"))

  @impl true
  def status(url), do: JsonConfig.status(path(), entry(url))

  @impl true
  def install(url), do: JsonConfig.install(path(), entry(url))

  @impl true
  def remove, do: JsonConfig.remove(path())

  defp path, do: Path.join(McpClients.home(), ".gemini/settings.json")

  defp entry(url), do: %{"httpUrl" => url}
end
