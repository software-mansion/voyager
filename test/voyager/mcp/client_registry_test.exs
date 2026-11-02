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

  test "all/0 is empty when the registry is not running" do
    assert ClientRegistry.all() == []
  end
end
