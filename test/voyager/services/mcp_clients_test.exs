defmodule Voyager.Services.McpClientsTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.McpClients

  @url "http://127.0.0.1:4040/mcp"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    Application.put_env(:voyager, :mcp_clients_home, home)

    on_exit(fn ->
      Application.delete_env(:voyager, :mcp_clients_installed)
      Application.delete_env(:voyager, :mcp_clients_home)
    end)
  end

  test "lists every client in display order, flagging the installed ones" do
    Application.put_env(:voyager, :mcp_clients_installed, [:cursor, :claude_code])

    assert Enum.map(McpClients.all(@url), &{&1.id, &1.installed?}) == [
             claude_code: true,
             codex: false,
             gemini: false,
             cursor: true
           ]
  end

  test "only cursor has an install link, carrying a base64 url config" do
    Application.put_env(:voyager, :mcp_clients_installed, [:claude_code, :codex, :gemini, :cursor])

    clients = Map.new(McpClients.all(@url), &{&1.id, &1})

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

  test "marks clients whose config already points at the url as added", %{tmp_dir: home} do
    write = fn path, contents ->
      File.mkdir_p!(Path.dirname(Path.join(home, path)))
      File.write!(Path.join(home, path), contents)
    end

    write.(
      ".claude.json",
      ~s({"projects":{"/p":{"mcpServers":{"v":{"type":"http","url":"#{@url}"}}}}})
    )

    write.(".cursor/mcp.json", ~s({"mcpServers":{"voyager":{"url":"http://127.0.0.1:1/mcp"}}}))
    write.(".gemini/settings.json", ~s({"mcpServers":{"voyager":{"httpUrl":"#{@url}"}}}))
    write.(".codex/config.toml", ~s([mcp_servers.voyager]\nurl = "#{@url}"\n))

    assert Map.new(McpClients.all(@url), &{&1.id, &1.added?}) == %{
             claude_code: true,
             codex: true,
             gemini: true,
             cursor: false
           }
  end

  test "finds executables on PATH but never looks inside privacy-protected folders", %{
    tmp_dir: home
  } do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    for dir <- ["bin", "Documents/bin"] do
      File.mkdir_p!(Path.join(home, dir))
      File.write!(Path.join([home, dir, "gemini"]), "")
    end

    System.put_env("PATH", Path.join(home, "Documents/bin"))
    refute gemini_installed?()

    System.put_env("PATH", Path.join(home, "bin"))
    assert gemini_installed?()
  end

  defp gemini_installed?,
    do: McpClients.all(@url) |> Enum.find(&(&1.id == :gemini)) |> Map.fetch!(:installed?)
end
