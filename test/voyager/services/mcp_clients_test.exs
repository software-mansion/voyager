defmodule Voyager.Services.McpClientsTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.McpClients

  @url "http://127.0.0.1:4040/mcp"
  @new_url "http://127.0.0.1:5050/mcp"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    Application.put_env(:voyager, :mcp_clients_home, home)
    on_exit(fn -> Application.delete_env(:voyager, :mcp_clients_home) end)
    %{home: home}
  end

  describe "json clients" do
    for {id, dir, file, entry} <- [
          {"claude_code", ".claude", ".claude.json", %{"type" => "http", "url" => "URL"}},
          {"cursor", ".cursor", ".cursor/mcp.json", %{"url" => "URL"}},
          {"gemini", ".gemini", ".gemini/settings.json", %{"httpUrl" => "URL"}}
        ] do
      @id id
      @config_dir dir
      @config_file file
      @entry entry

      setup %{home: home} do
        File.mkdir_p!(Path.join(home, @config_dir))
        :ok
      end

      test "#{id}: install keeps other keys, writes a backup, and remove drops only voyager", %{
        home: home
      } do
        path = Path.join(home, @config_file)
        File.mkdir_p!(Path.dirname(path))
        original = ~s({"theme":"dark","mcpServers":{"other":{"command":"x","env":null}}})
        File.write!(path, original)

        assert status(@id) == :missing
        assert McpClients.install(@id, @url) == :ok
        assert File.read!(path <> ".bak") == original

        config = path |> File.read!() |> JSON.decode!()
        assert config["theme"] == "dark"
        assert config["mcpServers"]["other"] == %{"command" => "x", "env" => nil}
        assert config["mcpServers"]["voyager"] == expected(@entry, @url)
        assert status(@id) == :configured

        assert McpClients.install(@id, @url) == :ok

        assert McpClients.statuses(@new_url) |> Enum.find(&(&1.id == @id)) |> Map.get(:status) ==
                 :outdated

        assert McpClients.remove(@id) == :ok
        config = path |> File.read!() |> JSON.decode!()
        assert config["mcpServers"] == %{"other" => %{"command" => "x", "env" => nil}}
        assert status(@id) == :missing
      end

      test "#{id}: install creates a missing config file", %{home: home} do
        assert McpClients.install(@id, @url) == :ok
        refute File.exists?(Path.join(home, @config_file <> ".bak"))
        assert status(@id) == :configured
      end

      test "#{id}: refuses to overwrite an unparsable config", %{home: home} do
        path = Path.join(home, @config_file)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "{not json")

        assert McpClients.install(@id, @url) == {:error, :invalid_config}
        assert File.read!(path) == "{not json"
      end
    end
  end

  describe "codex" do
    test "replaces only the voyager tables and keeps the rest", %{home: home} do
      path = Path.join(home, ".codex/config.toml")
      File.mkdir_p!(Path.dirname(path))

      original = """
      model = "o3"

      [mcp_servers.voyager]
      url = "http://127.0.0.1:1/mcp"

      [mcp_servers.voyager.env]
      A = "b"

      [mcp_servers.other]
      command = "x"
      """

      File.write!(path, original)

      assert status("codex") == :outdated
      assert McpClients.install("codex", @url) == :ok
      assert File.read!(path <> ".bak") == original

      contents = File.read!(path)
      assert contents =~ ~s(model = "o3")
      assert contents =~ "[mcp_servers.other]\ncommand = \"x\""
      refute contents =~ "voyager.env"
      assert contents =~ ~s([mcp_servers.voyager]\nurl = "#{@url}"\n)
      assert status("codex") == :configured

      assert McpClients.remove("codex") == :ok
      refute File.read!(path) =~ "voyager"
      assert File.read!(path) =~ "[mcp_servers.other]"
      assert status("codex") == :missing
    end
  end

  test "reports clients without a config dir as not detected", %{home: home} do
    File.mkdir_p!(Path.join(home, ".cursor"))

    assert McpClients.statuses(@url) |> Map.new(&{&1.id, &1.status}) == %{
             "claude_code" => :not_detected,
             "cursor" => :missing,
             "gemini" => :not_detected,
             "codex" => :not_detected
           }
  end

  test "cursor deeplink carries the base64 url config" do
    %URI{scheme: "cursor", query: query} = URI.parse(McpClients.cursor_deeplink(@url))
    %{"name" => "voyager", "config" => config} = URI.decode_query(query)
    assert config |> Base.decode64!() |> JSON.decode!() == %{"url" => @url}
  end

  defp status(id), do: McpClients.statuses(@url) |> Enum.find(&(&1.id == id)) |> Map.get(:status)

  defp expected(entry, url),
    do: Map.new(entry, fn {k, v} -> {k, String.replace(v, "URL", url)} end)
end
