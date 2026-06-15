defmodule Voyager.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Voyager.MCP.Server

  test "registers the connection_status and node_info tools" do
    names = Server.__components__(:tool) |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["connection_status", "node_info"]
  end
end
