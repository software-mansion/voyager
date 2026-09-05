defmodule Voyager.MCP.Tools.ProcessList do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Services.ProcessList

  schema do
    field :limit, :integer, required: true, max: 100
    field :sort_by, :enum, values: ProcessList.sortable_attrs(), default: :memory
    field :attrs, {:list, :enum}, values: ProcessList.allowed_attrs(), default: :memory
  end

  @impl true
  def description do
  end

  @impl true
  def execute(_params, frame) do
  end
end
