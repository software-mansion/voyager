defmodule Voyager.Services.McpClients.Codex do
  @moduledoc false
  @behaviour Voyager.Services.McpClients

  alias Voyager.Services.LocalFiles
  alias Voyager.Services.McpClients

  # ponytail: textual edit of our own tables only, swap for a TOML library if we ever need to parse more.
  @tables ~r/^\[mcp_servers\.(?:voyager|"voyager")(?:\.[^\]\n]+)?\][^\n]*\n?(?:[^\[\n][^\n]*\n?|\n)*/m
  @url ~r/^\[mcp_servers\.(?:voyager|"voyager")\][^\n]*\n(?:[^\[\n][^\n]*\n|\n)*?url\s*=\s*"([^"]*)"/m

  @impl true
  def detect?, do: File.dir?(Path.join(McpClients.home(), ".codex"))

  @impl true
  def status(url) do
    case File.read(path()) do
      {:ok, contents} -> contents_status(contents, url)
      {:error, _reason} -> :missing
    end
  end

  @impl true
  def install(url) do
    with {:ok, contents} <- read() do
      rest = contents |> strip() |> String.trim_trailing()
      separator = if rest == "", do: "", else: "\n\n"
      write(rest <> separator <> ~s|[mcp_servers.voyager]\nurl = "#{url}"\n|)
    end
  end

  @impl true
  def remove do
    with {:ok, contents} <- read() do
      if Regex.match?(@tables, contents), do: write(strip(contents)), else: :ok
    end
  end

  defp contents_status(contents, url) do
    case Regex.run(@url, contents, capture: :all_but_first) do
      [^url] -> :configured
      [_other] -> :outdated
      nil -> if Regex.match?(@tables, contents), do: :outdated, else: :missing
    end
  end

  defp strip(contents), do: Regex.replace(@tables, contents, "")

  defp read do
    case File.read(path()) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(contents) do
    with :ok <- McpClients.backup(path()), do: LocalFiles.write(path(), contents)
  end

  defp path, do: Path.join(McpClients.home(), ".codex/config.toml")
end
