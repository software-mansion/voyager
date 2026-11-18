defmodule Voyager.Services.McpConfigFileTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.McpConfigFile

  @url "http://127.0.0.1:4040/mcp"
  @entry %{"type" => "http", "url" => @url}

  @moduletag :tmp_dir

  describe "json" do
    test "creates a missing file and its folder", %{tmp_dir: dir} do
      path = Path.join([dir, "nested", "mcp.json"])

      assert :ok = McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)

      assert JSON.decode!(File.read!(path)) == %{"mcpServers" => %{"voyager" => @entry}}
      assert {:ok, %{"voyager" => @entry}} = McpConfigFile.servers(path, :json, ["mcpServers"])
    end

    test "treats an empty file as an empty config", %{tmp_dir: dir} do
      path = Path.join(dir, "settings.json")
      File.write!(path, "\n")

      assert {:ok, servers} = McpConfigFile.servers(path, :json, ["mcpServers"])
      assert servers == %{}
      assert :ok = McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)
      assert JSON.decode!(File.read!(path))["mcpServers"]["voyager"] == @entry
    end

    test "keeps other keys, servers and their order", %{tmp_dir: dir} do
      path = Path.join(dir, ".claude.json")

      File.write!(path, """
      {"zeta": 1, "mcpServers": {"other": {"command": "x"}}, "alpha": {"b": 2, "a": 1}}
      """)

      assert :ok = McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)

      written = File.read!(path)
      decoded = JSON.decode!(written)

      assert decoded["mcpServers"] == %{"other" => %{"command" => "x"}, "voyager" => @entry}
      assert decoded["zeta"] == 1
      assert decoded["alpha"] == %{"b" => 2, "a" => 1}
      assert ordered_keys(written) == ["zeta", "mcpServers", "alpha"]
    end

    test "creates nested keys that are missing", %{tmp_dir: dir} do
      path = Path.join(dir, "opencode.json")
      File.write!(path, ~s({"theme": "dark"}))

      assert :ok = McpConfigFile.put_server(path, :json, ["mcp", "servers"], @entry)
      assert JSON.decode!(File.read!(path))["mcp"]["servers"]["voyager"] == @entry
    end

    test "keeps the file mode", %{tmp_dir: dir} do
      path = Path.join(dir, ".claude.json")
      File.write!(path, "{}")
      File.chmod!(path, 0o600)

      assert :ok = McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "writes through a symlink instead of replacing it", %{tmp_dir: dir} do
      target = Path.join(dir, "dotfiles.json")
      link = Path.join(dir, "mcp.json")
      File.write!(target, "{}")
      File.ln_s!(target, link)

      assert :ok = McpConfigFile.put_server(link, :json, ["mcpServers"], @entry)

      assert {:ok, _target} = File.read_link(link)
      assert JSON.decode!(File.read!(target))["mcpServers"]["voyager"] == @entry
    end

    test "refuses JSONC and leaves the file untouched", %{tmp_dir: dir} do
      path = Path.join(dir, "settings.json")
      contents = ~s(// Zed settings\n{"theme": "One Dark",}\n)
      File.write!(path, contents)

      assert {:error, :invalid_json} = McpConfigFile.servers(path, :json, ["context_servers"])

      assert {:error, :invalid_json} =
               McpConfigFile.put_server(path, :json, ["context_servers"], @entry)

      assert File.read!(path) == contents
    end

    test "delete removes only the voyager server", %{tmp_dir: dir} do
      path = Path.join(dir, "mcp.json")
      File.write!(path, ~s({"theme": 1, "mcpServers": {"other": {"url": "x"}}}))
      :ok = McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)

      assert :ok = McpConfigFile.delete_server(path, :json, ["mcpServers"])

      assert JSON.decode!(File.read!(path)) ==
               %{"theme" => 1, "mcpServers" => %{"other" => %{"url" => "x"}}}
    end

    test "delete leaves a file without voyager untouched", %{tmp_dir: dir} do
      path = Path.join(dir, "mcp.json")
      contents = ~s({"mcpServers":{"other":{"url":"x"}}})
      File.write!(path, contents)

      assert :ok = McpConfigFile.delete_server(path, :json, ["mcpServers"])
      assert File.read!(path) == contents

      missing = Path.join(dir, "missing.json")
      assert :ok = McpConfigFile.delete_server(missing, :json, ["mcpServers"])
      refute File.exists?(missing)
    end

    test "refuses a servers key that is not an object", %{tmp_dir: dir} do
      path = Path.join(dir, "mcp.json")
      File.write!(path, ~s({"mcpServers": []}))

      assert {:error, :unexpected_shape} = McpConfigFile.servers(path, :json, ["mcpServers"])

      assert {:error, :unexpected_shape} =
               McpConfigFile.put_server(path, :json, ["mcpServers"], @entry)
    end
  end

  describe "toml" do
    test "appends a table and keeps comments", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      # my settings
      model = "gpt-5"

      [mcp_servers.other]
      command = "other"
      """)

      assert :ok = McpConfigFile.put_server(path, :toml, ["mcp_servers"], %{"url" => @url})

      assert File.read!(path) == """
             # my settings
             model = "gpt-5"

             [mcp_servers.other]
             command = "other"

             [mcp_servers.voyager]
             url = "#{@url}"
             """

      assert {:ok, %{"other" => %{}, "voyager" => %{"url" => @url}}} =
               McpConfigFile.servers(path, :toml, ["mcp_servers"])
    end

    test "replaces a stale voyager table", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      [mcp_servers.voyager]
      url = "http://127.0.0.1:1234/mcp"

      [mcp_servers.voyager.tools.node_info]
      approval_mode = "approve"
      """)

      assert {:ok, %{"voyager" => %{"url" => "http://127.0.0.1:1234/mcp"}}} =
               McpConfigFile.servers(path, :toml, ["mcp_servers"])

      assert :ok = McpConfigFile.put_server(path, :toml, ["mcp_servers"], %{"url" => @url})

      assert File.read!(path) == """
             [mcp_servers.voyager.tools.node_info]
             approval_mode = "approve"

             [mcp_servers.voyager]
             url = "#{@url}"
             """
    end

    test "delete removes the voyager table and its subtables", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      # my settings
      [mcp_servers.voyager]
      url = "#{@url}"

      [mcp_servers.voyager.tools.node_info]
      approval_mode = "approve"

      [mcp_servers.other]
      command = "other"
      """)

      assert :ok = McpConfigFile.delete_server(path, :toml, ["mcp_servers"])

      assert File.read!(path) == """
             # my settings
             [mcp_servers.other]
             command = "other"
             """
    end

    test "delete leaves a toml file without voyager untouched", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")
      contents = "model = \"gpt-5\"\n"
      File.write!(path, contents)

      assert :ok = McpConfigFile.delete_server(path, :toml, ["mcp_servers"])
      assert File.read!(path) == contents
    end

    test "delete removes a single-quoted voyager table", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")
      File.write!(path, "model = \"gpt-5\"\n\n[mcp_servers.'voyager']\nurl = \"#{@url}\"\n")

      assert {:ok, %{"voyager" => %{"url" => @url}}} =
               McpConfigFile.servers(path, :toml, ["mcp_servers"])

      assert :ok = McpConfigFile.delete_server(path, :toml, ["mcp_servers"])
      assert File.read!(path) == "model = \"gpt-5\"\n"
    end

    test "refuses inline or dotted voyager definitions and leaves the file untouched", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "config.toml")

      for contents <- [
            ~s(mcp_servers = { voyager = { url = "#{@url}" } }\n),
            ~s([mcp_servers]\nvoyager = { url = "#{@url}" }\n),
            ~s(mcp_servers.voyager.url = "#{@url}"\n)
          ] do
        File.write!(path, contents)

        assert {:error, :unsupported_toml} = McpConfigFile.servers(path, :toml, ["mcp_servers"])

        assert {:error, :unsupported_toml} =
                 McpConfigFile.put_server(path, :toml, ["mcp_servers"], %{"url" => @url})

        assert {:error, :unsupported_toml} =
                 McpConfigFile.delete_server(path, :toml, ["mcp_servers"])

        assert File.read!(path) == contents
      end
    end

    test "ignores headers inside multiline strings", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")

      instructions = """
      instructions = \"\"\"
      Example:
      [mcp_servers.voyager]
      url = "http://example.com"
      \"\"\"
      """

      File.write!(path, instructions)

      assert {:ok, servers} = McpConfigFile.servers(path, :toml, ["mcp_servers"])
      assert servers == %{}

      assert :ok = McpConfigFile.put_server(path, :toml, ["mcp_servers"], %{"url" => @url})
      assert File.read!(path) == instructions <> "\n[mcp_servers.voyager]\nurl = \"#{@url}\"\n"

      assert :ok = McpConfigFile.delete_server(path, :toml, ["mcp_servers"])
      assert File.read!(path) == instructions
    end

    test "creates a missing file", %{tmp_dir: dir} do
      path = Path.join([dir, ".codex", "config.toml"])

      assert :ok = McpConfigFile.put_server(path, :toml, ["mcp_servers"], %{"url" => @url})
      assert File.read!(path) == "[mcp_servers.voyager]\nurl = \"#{@url}\"\n"
    end
  end

  defp ordered_keys(json) do
    {:ok, %Jason.OrderedObject{values: values}} = Jason.decode(json, objects: :ordered_objects)
    Enum.map(values, &elem(&1, 0))
  end
end
