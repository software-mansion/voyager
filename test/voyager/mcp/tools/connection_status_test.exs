defmodule Voyager.MCP.Tools.ConnectionStatusTest do
  # async: false — reads the globally-registered Voyager.NodeSession state.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.ConnectionStatus

  test "reports connected: false when no node is connected" do
    refute Voyager.NodeSession.connected?()

    assert {:reply, response, %Frame{}} = ConnectionStatus.execute(%{}, %Frame{})

    payload = decode_tool_json(response)
    assert payload == %{"connected" => false}
  end

  defp decode_tool_json(response) do
    %{"content" => [%{"type" => "text", "text" => json} | _]} =
      Response.to_protocol(response)

    JSON.decode!(json)
  end
end
