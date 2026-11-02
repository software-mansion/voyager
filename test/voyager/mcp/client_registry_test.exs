defmodule Voyager.MCP.ClientRegistryTest do
  use ExUnit.Case, async: false

  alias Voyager.MCP.ClientRegistry

  test "records clients by name and broadcasts the list" do
    start_supervised!(ClientRegistry)
    Phoenix.PubSub.subscribe(Voyager.PubSub, ClientRegistry.topic())

    ClientRegistry.seen(%{"name" => "claude-code", "version" => "2.1.0"})
    ClientRegistry.seen(%{"name" => "claude-code", "version" => "2.1.1"})
    ClientRegistry.seen(nil)

    assert_receive {:mcp_clients, [%{name: "claude-code", version: "2.1.0"}]}
    assert_receive {:mcp_clients, [%{name: "claude-code", version: "2.1.1"}]}

    assert [%{name: "claude-code", version: "2.1.1", last_seen: %DateTime{}}] =
             ClientRegistry.all()
  end

  test "drops clients idle for more than five minutes" do
    pid = start_supervised!(ClientRegistry)
    ClientRegistry.seen(%{"name" => "codex-mcp-client", "version" => "0.50.0"})
    ClientRegistry.seen(%{"name" => "claude-code", "version" => "2.1.0"})

    :sys.replace_state(pid, fn clients ->
      put_in(clients["codex-mcp-client"].last_seen, DateTime.add(DateTime.utc_now(), -301))
    end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, ClientRegistry.topic())
    send(pid, :prune)

    assert_receive {:mcp_clients, [%{name: "claude-code"}]}
    assert [%{name: "claude-code"}] = ClientRegistry.all()
  end

  test "all/0 is empty when the registry is not running" do
    assert ClientRegistry.all() == []
  end
end
