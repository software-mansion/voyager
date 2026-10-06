defmodule Voyager.MCP.Server do
  @moduledoc """
  MCP server exposing BEAM node introspection to coding agents.
  """

  use Anubis.Server,
    name: "Voyager",
    version: Voyager.version(),
    capabilities: [:tools]

  alias Voyager.MCP.Tracing

  component(Voyager.MCP.Tools.NodeInfo)
  component(Voyager.MCP.Tools.ProcessList)
  component(Voyager.MCP.Tools.ProcessInfo)
  component(Voyager.MCP.Tools.EtsList)
  component(Voyager.MCP.Tools.EtsReadTableChunk)
  component(Voyager.MCP.Tools.EtsSearchTable)
  component(Voyager.MCP.Tools.TracePropose)
  component(Voyager.MCP.Tools.TraceRequest)
  component(Voyager.MCP.Tools.TraceResult)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @impl true
  def handle_elicitation(answer, _request_id, frame),
    do: {:noreply, Tracing.handle_answer(answer, frame)}
end
