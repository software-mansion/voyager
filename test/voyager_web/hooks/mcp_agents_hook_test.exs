defmodule VoyagerWeb.Hooks.McpAgentsHookTest do
  # async: false because these tests replace the app's NodeSession and use Mox global mode.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Voyager.Fakes, only: [stub_erpc: 1]

  alias Voyager.Fakes
  alias Voyager.Services.McpAgents

  @url "http://127.0.0.1:4040/mcp"
  @path "/node/demo@localhost"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
    stub_erpc(Fakes.node_data())
    :ok
  end

  test "lists recently used and added agents, not the rest", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    broadcast(%McpAgents{
      server: %{alive?: true, url: @url},
      agents: [
        agent(:claude_code, "Claude Code", :added),
        agent(:cursor, "Cursor", :added),
        agent(:codex, "Codex", :not_added)
      ],
      recent: [
        %{name: "claude-code", version: "2.1.0", agent_id: :claude_code},
        %{name: "mcp-inspector", version: "0.1.0", agent_id: nil}
      ]
    })

    assert tip_has?(view, "#mcp-status-headline", "2 agents used recently")
    assert tip_has?(view, "#mcp-status-agent-claude_code", "Recently used")
    assert tip_has?(view, "#mcp-status-agent-claude_code", "2.1.0")
    assert tip_has?(view, "#mcp-status-agent-cursor", "Added")
    assert tip_has?(view, "#mcp-status-agents li", "mcp-inspector")
    refute tip_has?(view, "#mcp-status-agent-codex")
    assert tip_has?(view, "#mcp-status-url", @url)
  end

  test "shows a setup link when no agent has Voyager", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    broadcast(%McpAgents{
      server: %{alive?: true, url: @url},
      agents: [agent(:codex, "Codex", :not_added)]
    })

    assert tip_has?(view, "#mcp-status-headline", "MCP server running")
    assert tip_has?(view, "#mcp-status-empty")
    assert tip_has?(view, ~s|#mcp-status-settings[href="/settings#mcp-server"]|, "Set up agents")
  end

  test "points to settings while the server is stopped", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    broadcast(%McpAgents{server: %{alive?: false, url: @url}})

    assert tip_has?(view, "#mcp-status-stopped", "Open Settings")
    refute tip_has?(view, "#mcp-status-running")
  end

  defp agent(id, name, status) do
    %{id: id, name: name, path: "~/.config", detected?: true, status: status, snippet: ""}
  end

  # Tooltip content is portaled into a <template>, which element queries do not look inside.
  defp tip_has?(view, selector, text \\ nil) do
    nodes =
      view
      |> element("[id^=mcp-status-tip-][id$=-portal]")
      |> render()
      |> String.replace(~r{</?template[^>]*>}, "")
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)

    not Enum.empty?(nodes) and (text == nil or LazyHTML.text(nodes) =~ text)
  end

  defp broadcast(snapshot) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, McpAgents.topic(), {:mcp_agents, snapshot})
  end
end
