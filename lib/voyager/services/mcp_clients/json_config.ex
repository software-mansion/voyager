defmodule Voyager.Services.McpClients.JsonConfig do
  @moduledoc false

  alias Voyager.Services.LocalFiles
  alias Voyager.Services.McpClients

  @key "voyager"

  @spec status(Path.t(), map()) :: McpClients.status()
  def status(path, entry) do
    case read(path) do
      {:ok, %{"mcpServers" => %{@key => current}}} when is_map(current) ->
        if Map.take(current, Map.keys(entry)) == entry, do: :configured, else: :outdated

      _ ->
        :missing
    end
  end

  @spec install(Path.t(), map()) :: :ok | {:error, term()}
  def install(path, entry) do
    with {:ok, config} <- read(path) do
      servers = Map.get(config, "mcpServers") || %{}
      write(path, Map.put(config, "mcpServers", Map.put(servers, @key, entry)))
    end
  end

  @spec remove(Path.t()) :: :ok | {:error, term()}
  def remove(path) do
    case read(path) do
      {:ok, %{"mcpServers" => %{@key => _} = servers} = config} ->
        write(path, Map.put(config, "mcpServers", Map.delete(servers, @key)))

      {:ok, _config} ->
        :ok

      error ->
        error
    end
  end

  # :json keeps `null` as an atom, so a decode/format round trip is lossless, unlike JSON with nil.
  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        case :json.decode(contents) do
          config when is_map(config) -> {:ok, config}
          _ -> {:error, :invalid_config}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ErlangError -> {:error, :invalid_config}
  end

  defp write(path, config) do
    with :ok <- McpClients.backup(path) do
      LocalFiles.write(path, [:json.format(config), ?\n])
    end
  end
end
