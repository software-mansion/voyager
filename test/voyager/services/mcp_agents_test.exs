defmodule Voyager.Services.McpAgentsTest do
  use Voyager.DataCase, async: false

  alias Voyager.MCP
  alias Voyager.Services.McpAgents

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup %{tmp_dir: home} do
    Application.put_env(:voyager, :mcp_clients_home, home)
    Application.put_env(:voyager, :mcp_clients_installed, [])

    on_exit(fn ->
      Application.delete_env(:voyager, :mcp_clients_installed)
      Application.delete_env(:voyager, :mcp_clients_home)
    end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, McpAgents.topic())
    :ok
  end

  test "is off until the server runs, on until an agent calls, then connected" do
    start_supervised!(McpAgents)
    assert %McpAgents{state: :off, url: url} = McpAgents.get()

    Phoenix.PubSub.broadcast(
      Voyager.PubSub,
      MCP.topic(),
      {:mcp_status, %{alive?: true, url: url}}
    )

    assert_receive {:mcp_agents, %McpAgents{state: :on, connected: []}}

    McpAgents.seen(%{"name" => "claude-code", "version" => "2.1.0"})

    assert_receive {:mcp_agents,
                    %McpAgents{
                      state: :connected,
                      connected: [
                        %{id: :claude_code, name: "Claude Code", connection: connection}
                      ]
                    }}

    assert %{client: "claude-code", version: "2.1.0"} = connection
  end

  test "lists agents found on this machine, then connected agents it does not know", %{
    tmp_dir: home
  } do
    Application.put_env(:voyager, :mcp_clients_installed, [:cursor])
    url = MCP.info().url
    File.mkdir_p!(Path.join(home, ".gemini"))

    File.write!(
      Path.join(home, ".gemini/settings.json"),
      JSON.encode!(%{mcpServers: %{v: %{httpUrl: url}}})
    )

    start_supervised!(McpAgents)
    McpAgents.seen(%{"name" => "zed", "version" => "0.200"})
    assert_receive {:mcp_agents, %McpAgents{agents: [_, _, _]} = agents}

    assert [
             %{id: :gemini, added?: true, connection: nil},
             %{id: :cursor, installed?: true, added?: false},
             %{id: nil, name: "zed", connection: %{version: "0.200"}}
           ] = agents.agents
  end

  test "rescans the machine on refresh" do
    start_supervised!(McpAgents)
    assert McpAgents.get().agents == []

    Application.put_env(:voyager, :mcp_clients_installed, [:codex])
    McpAgents.refresh()

    assert_receive {:mcp_agents,
                    %McpAgents{agents: [%{id: :codex, command: "codex mcp add" <> _}]}}
  end

  test "ignores nameless and recovered sessions" do
    start_supervised!(McpAgents)
    assert_receive {:mcp_agents, %McpAgents{}}
    McpAgents.seen(nil)
    McpAgents.seen(%{"name" => "auto-recovered", "version" => "unknown"})

    assert McpAgents.get().connected == []
    refute_received {:mcp_agents, _}
  end

  test "forgets agents idle for more than ten minutes" do
    pid = start_supervised!(McpAgents)
    McpAgents.seen(%{"name" => "codex-mcp-client", "version" => "0.50.0"})
    McpAgents.seen(%{"name" => "claude-code", "version" => "2.1.0"})
    assert_receive {:mcp_agents, %McpAgents{connected: [_, _]}}

    :sys.replace_state(pid, fn state ->
      stale = DateTime.add(DateTime.utc_now(), -601)
      put_in(state.connections["codex-mcp-client"].last_seen, stale)
    end)

    send(pid, :prune)

    assert_receive {:mcp_agents, %McpAgents{agents: [%{id: :claude_code}], connected: [_]}}
  end

  test "reports off when it is not running" do
    assert %McpAgents{state: :off, agents: [], connected: []} = McpAgents.get()
  end
end
