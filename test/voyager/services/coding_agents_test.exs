defmodule Voyager.Services.CodingAgentsTest do
  # async: false because the home directory comes from application env.
  use ExUnit.Case, async: false

  alias Voyager.Services.CodingAgents

  @url "http://127.0.0.1:4040/mcp"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous = Application.get_env(:voyager, :coding_agents_home)
    Application.put_env(:voyager, :coding_agents_home, home)
    on_exit(fn -> Application.put_env(:voyager, :coding_agents_home, previous) end)
  end

  test "lists every agent argent supports, undetected and not added in an empty home" do
    agents = CodingAgents.scan(@url)

    assert Enum.map(agents, & &1.id) ==
             [
               :cursor,
               :claude_code,
               :vscode,
               :copilot,
               :zed,
               :antigravity,
               :codex,
               :opencode
             ]

    assert Enum.all?(agents, &(not &1.detected?))
    assert Enum.all?(agents, &(&1.status == :not_added))
  end

  test "detects an agent from its folder", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".codex"))

    agents = CodingAgents.scan(@url)

    assert agent(agents, :codex).detected?
    refute agent(agents, :cursor).detected?
    assert agent(agents, :codex).path == "~/.codex/config.toml"
  end

  test "install points the agent at the url" do
    for id <- [:claude_code, :codex, :opencode, :copilot, :antigravity] do
      assert :ok = CodingAgents.install(id, @url)
      assert agent(CodingAgents.scan(@url), id).status == :added
    end
  end

  test "remove takes voyager out of the agent's config" do
    :ok = CodingAgents.install(:codex, @url)
    assert agent(CodingAgents.scan(@url), :codex).removable?

    assert :ok = CodingAgents.remove(:codex)

    codex = agent(CodingAgents.scan(@url), :codex)
    assert codex.status == :not_added
    refute codex.removable?
  end

  test "an entry pointing at another port is outdated" do
    :ok = CodingAgents.install(:cursor, "http://127.0.0.1:1234/mcp")

    assert agent(CodingAgents.scan(@url), :cursor).status == :outdated

    :ok = CodingAgents.install(:cursor, @url)
    assert agent(CodingAgents.scan(@url), :cursor).status == :added
  end

  test "a server added under another name with the same url counts as added", %{tmp_dir: home} do
    File.write!(
      Path.join(home, ".claude.json"),
      ~s({"mcpServers": {"beam": {"type": "http", "url": "#{@url}"}}})
    )

    claude_code = agent(CodingAgents.scan(@url), :claude_code)
    assert claude_code.status == :added
    refute claude_code.removable?
  end

  test "a config that is not plain JSON must be edited by hand", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".config/zed"))
    File.write!(Path.join(home, ".config/zed/settings.json"), "// comment\n{}")

    zed = agent(CodingAgents.scan(@url), :zed)

    assert zed.status == :manual
    assert JSON.decode!(zed.snippet) == %{"context_servers" => %{"voyager" => %{"url" => @url}}}
  end

  test "a disabled opencode entry is outdated so it can be re-enabled", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".config/opencode"))

    File.write!(
      Path.join(home, ".config/opencode/opencode.json"),
      ~s({"mcp": {"voyager": {"type": "remote", "url": "#{@url}", "enabled": false}}})
    )

    assert agent(CodingAgents.scan(@url), :opencode).status == :outdated

    :ok = CodingAgents.install(:opencode, @url)
    assert agent(CodingAgents.scan(@url), :opencode).status == :added
  end

  test "opencode prefers an existing opencode.jsonc", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".config/opencode"))
    File.write!(Path.join(home, ".config/opencode/opencode.jsonc"), "{}")

    assert agent(CodingAgents.scan(@url), :opencode).path == "~/.config/opencode/opencode.jsonc"
  end

  test "match maps client names to agents" do
    assert CodingAgents.match("claude-code") == :claude_code
    assert CodingAgents.match("codex-mcp-client") == :codex
    assert CodingAgents.match("cursor-vscode") == :cursor
    assert CodingAgents.match("Visual Studio Code") == :vscode
    assert CodingAgents.match("github-copilot-cli") == :copilot
    assert CodingAgents.match("antigravity-cli") == :antigravity
    assert CodingAgents.match("Zed") == :zed
    assert CodingAgents.match("mcp-inspector") == nil
  end

  test "fetch only accepts known ids" do
    assert CodingAgents.fetch("claude_code") == {:ok, :claude_code}
    assert CodingAgents.fetch("not_an_agent") == :error
  end

  defp agent(agents, id), do: Enum.find(agents, &(&1.id == id))
end
