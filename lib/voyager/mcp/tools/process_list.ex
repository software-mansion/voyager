defmodule Voyager.MCP.Tools.ProcessList do
  @moduledoc """
  Ranks the processes of the connected node by one attribute and returns the top
  `limit` of them.

  Ranking runs on the remote node, so only the returned rows cross the wire.
  Choose the columns with `attrs`; only cheap fixed-size attributes are
  available here -- a mailbox, dictionary or stacktrace needs `process_info`.
  `total_scanned` is the number of processes walked, before `limit` and `search`
  are applied. Memory is in bytes.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.Agent
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.ProcessList

  @sortable Enum.map(ProcessList.sortable_attrs(), &Atom.to_string/1)
  @allowed Enum.map(ProcessList.allowed_attrs(), &Atom.to_string/1)
  @by_name Map.new(ProcessList.allowed_attrs(), &{Atom.to_string(&1), &1})

  @default_attrs ~w(memory reductions message_queue_len registered_name)

  schema do
    field :limit, :integer,
      default: 25,
      min: 1,
      max: 100,
      description: "How many processes to return."

    field :sort_by, :enum,
      values: @sortable,
      default: "memory",
      description: "Attribute to rank on."

    field :direction, :enum,
      values: ~w(desc asc),
      default: "desc",
      description: "`desc` ranks largest first, `asc` smallest first."

    field :attrs, {:list, {:enum, @allowed}},
      default: @default_attrs,
      description: "Columns to return per process. `sort_by` is always included."

    field :search, :string,
      description: "Case-insensitive filter on the pid or any non-numeric column."
  end

  @impl true
  def execute(params, frame) do
    attrs = Enum.map(params.attrs, &Map.fetch!(@by_name, &1))
    sort_by = Map.fetch!(@by_name, params.sort_by)
    direction = if params.direction == "asc", do: :asc, else: :desc
    search = Map.get(params, :search)

    Remote.reply(&top(&1, attrs, sort_by, params.limit, direction, search), frame)
  end

  defp top(node, attrs, sort_by, limit, direction, search) do
    with {:ok, {entries, total}} <-
           ProcessList.top(
             node,
             attrs,
             sort_by,
             limit,
             Agent.default_timeout(),
             direction,
             search
           ) do
      {:ok, %{total_scanned: total, processes: entries}}
    end
  end
end
