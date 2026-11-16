defmodule Voyager.Services.McpAgentsTest do
  # async: false because these tests drive the app's McpAgents and the agents' home directory.
  use ExUnit.Case, async: false

  alias Voyager.Services.McpAgents

  @url "http://127.0.0.1:4040/mcp"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous_home = Application.get_env(:voyager, :coding_agents_home)
    previous_state = :sys.get_state(McpAgents)
    Application.put_env(:voyager, :coding_agents_home, home)

    on_exit(fn ->
      Application.put_env(:voyager, :coding_agents_home, previous_home)
      :sys.replace_state(McpAgents, fn _ -> previous_state end)
    end)

    :sys.replace_state(McpAgents, fn state ->
      %{state | server: %{alive?: true, url: @url}, calls: %{}}
    end)

    McpAgents.refresh()
    _ = :sys.get_state(McpAgents)
    Phoenix.PubSub.subscribe(Voyager.PubSub, McpAgents.topic())
    :ok
  end

  test "a tool call marks its client as recently used" do
    McpAgents.tool_called(%{"name" => "claude-code", "version" => "2.1.0"})

    assert_receive {:mcp_agents,
                    %McpAgents{
                      recent: [%{name: "claude-code", version: "2.1.0", agent_id: :claude_code}]
                    }}
  end

  test "repeated calls from a recent client do not broadcast again" do
    McpAgents.tool_called(%{"name" => "codex-mcp-client", "version" => "1.0"})
    assert_receive {:mcp_agents, %McpAgents{recent: [_client]}}

    McpAgents.tool_called(%{"name" => "codex-mcp-client", "version" => "1.0"})
    _ = :sys.get_state(McpAgents)

    refute_received {:mcp_agents, _snapshot}
  end

  test "ignores sessions anubis restored after a restart" do
    McpAgents.tool_called(%{"name" => "auto-recovered", "version" => "unknown"})
    McpAgents.tool_called(nil)
    _ = :sys.get_state(McpAgents)

    assert McpAgents.get().recent == []
  end

  test "a client drops off once its last call is older than five minutes" do
    McpAgents.tool_called(%{"name" => "claude-code", "version" => "2.1.0"})
    _ = :sys.get_state(McpAgents)

    send(McpAgents, {:expire, "claude-code"})
    assert [%{name: "claude-code"}] = McpAgents.get().recent

    long_ago = System.monotonic_time(:millisecond) - :timer.minutes(6)
    :sys.replace_state(McpAgents, &put_in(&1, [:calls, "claude-code", :at], long_ago))
    send(McpAgents, {:expire, "claude-code"})

    assert McpAgents.get().recent == []
  end

  test "install writes the config and broadcasts the agent as added" do
    assert :ok = McpAgents.install(:cursor)

    assert_receive {:mcp_agents, %McpAgents{agents: agents}}
    assert Enum.find(agents, &(&1.id == :cursor)).status == :added
  end

  test "remove broadcasts the agent as not added" do
    :ok = McpAgents.install(:cursor)
    assert_receive {:mcp_agents, _added}

    assert :ok = McpAgents.remove(:cursor)

    assert_receive {:mcp_agents, %McpAgents{agents: agents}}
    assert Enum.find(agents, &(&1.id == :cursor)).status == :not_added
  end

  test "a new url rescans the agents" do
    :ok = McpAgents.install(:cursor)

    send(McpAgents, {:mcp_status, %{alive?: true, url: "http://127.0.0.1:5050/mcp"}})

    assert Enum.find(McpAgents.get().agents, &(&1.id == :cursor)).status == :outdated
  end
end
