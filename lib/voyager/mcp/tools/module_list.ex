defmodule Voyager.MCP.Tools.ModuleList do
  @moduledoc """
  Finds tracing targets on the connected node: loaded modules, or one module's
  functions.

  Without `module`, searches loaded modules by name and pages through them with
  `limit`/`offset`; `total` counts every match, `next_offset` is `null` on the
  last page. Modules the agent refuses to trace are left out, and so are modules
  that are on the code path but not loaded. `traceability` is `ok`, or `hot`
  for modules that can only be traced on a list of pids.

  With `module` (`Foo.Bar`, `Elixir.Foo.Bar`, `:lists` or `lists`), lists that
  module's functions and arities, local ones included with `exported: false`,
  paged the same way. Results are cached for up to a minute.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.ModuleCatalog

  schema do
    field :module, :string,
      description: "Module to list the functions of. Omit to search modules instead."

    field :search, :string,
      description: "Case-insensitive substring of the module name. Ignored with `module`."

    field :limit, :integer,
      default: 50,
      min: 1,
      max: 500,
      description: "How many modules or functions to return."

    field :offset, :integer,
      default: 0,
      min: 0,
      description: "How many matches to skip, from a previous `next_offset`."
  end

  @impl true
  def execute(params, frame) do
    case String.trim(Map.get(params, :module) || "") do
      "" -> Remote.reply(&modules(&1, params), frame)
      module -> Remote.reply(&functions(&1, module, params), frame)
    end
  end

  defp modules(node, params) do
    with {:ok, entries} <- ModuleCatalog.modules(node, Map.get(params, :search)) do
      entries
      |> Enum.reject(&(&1.traceability == :refused))
      |> Enum.map(&Map.take(&1, [:name, :traceability]))
      |> page(params, :modules)
      |> then(&{:ok, &1})
    end
  end

  defp functions(node, input, params) do
    with {:ok, entries} <- ModuleCatalog.modules(node),
         {:ok, entry} <- find_module(entries, input),
         {:ok, functions} <- ModuleCatalog.functions(node, entry.module) do
      payload =
        functions
        |> Enum.map(&%{name: &1.name, arity: &1.arity, exported: &1.exported?})
        |> page(params, :functions)

      {:ok, Map.merge(payload, %{module: entry.name, traceability: entry.traceability})}
    end
  end

  defp find_module(entries, input) do
    candidates = [input, "Elixir." <> input, String.trim_leading(input, ":")]

    case Enum.find(entries, &(&1.name == input or Atom.to_string(&1.module) in candidates)) do
      nil -> {:error, {:not_loaded, input}}
      %{traceability: :refused} -> {:error, {:refused, input}}
      entry -> {:ok, entry}
    end
  end

  defp page(items, %{limit: limit, offset: offset}, key) do
    total = length(items)
    next_offset = if offset + limit < total, do: offset + limit

    %{key => Enum.slice(items, offset, limit), total: total, next_offset: next_offset}
  end
end
