defmodule Voyager.MCP.Tools.ProcessInfo do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Services.ProcessInfo

  schema do
  end

  @impl true
  def execute(_params, frame) do
  end
end
