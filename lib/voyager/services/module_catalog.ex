defmodule Voyager.Services.ModuleCatalog do
  @moduledoc """
  Loaded modules and their functions on a remote node, cached per node.

  Entries expire after a TTL (`config :voyager, :module_catalog_ttl_ms`) and are
  dropped when the node session changes, so hot-loaded and lazily loaded
  modules show up without a manual `refresh/1`. Only loaded modules are listed,
  since the agent refuses to trace the rest.

  The traceability tag comes from the agent's own refusal check and only helps
  the UI: `trace_start` validates again on the node.
  """

  use GenServer

  alias Voyager.Agent
  alias Voyager.NodeSession

  @table __MODULE__
  @default_ttl_ms 60_000
  @timeout Agent.default_timeout()

  @typedoc "`:hot` modules can only be traced on a list of pids."
  @type traceability :: :ok | :hot | :refused
  @type module_entry :: %{module: module(), name: String.t(), traceability: traceability()}
  @type function_entry :: %{name: atom(), arity: arity(), exported?: boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Loaded modules whose display name (`Foo.Bar`, `:lists`) contains `filter`,
  case-insensitively, sorted by name. A `nil` or blank filter returns all.
  """
  @spec modules(node(), String.t() | nil) :: {:ok, [module_entry()]} | {:error, term()}
  def modules(node, filter \\ nil) do
    with {:ok, entries} <- cached(node, :modules, fn -> fetch_modules(node) end) do
      {:ok, filter_modules(entries, normalize_filter(filter))}
    end
  end

  @doc """
  Every function of a loaded `module`, local ones included, sorted by name and
  arity. Compiler-generated funs are left out.
  """
  @spec functions(node(), module()) :: {:ok, [function_entry()]} | {:error, term()}
  def functions(node, module) when is_atom(module) do
    cached(node, {:functions, module}, fn -> fetch_functions(node, module) end)
  end

  @doc "Drops everything cached for `node`, so the next lookup refetches."
  @spec refresh(node()) :: :ok
  def refresh(node) do
    :ets.update_counter(@table, {node, :generation}, 1, {{node, :generation}, 0})
    :ets.match_delete(@table, {{node, :_, :_}, :_, :_})
    :ok
  end

  # A fetch that finishes after refresh/1 writes under the old generation, which is never read.
  defp cached(node, key, fetch) do
    cache_key = {node, generation(node), key}
    now = System.monotonic_time(:millisecond)
    ttl_ms = ttl_ms()

    case :ets.lookup(@table, cache_key) do
      [{_key, value, fetched_at}] when now - fetched_at < ttl_ms ->
        {:ok, value}

      _miss ->
        with {:ok, value} <- fetch.() do
          :ets.insert(@table, {cache_key, value, now})
          {:ok, value}
        end
    end
  end

  defp generation(node) do
    case :ets.lookup(@table, {node, :generation}) do
      [{_key, generation}] -> generation
      [] -> 0
    end
  end

  defp fetch_modules(node) do
    with {:ok, modules} <- Agent.call(node, :trace_modules, [], @timeout) do
      entries =
        modules
        |> Enum.map(fn {module, traceability} ->
          name = inspect(module)
          {%{module: module, name: name, traceability: traceability}, String.downcase(name)}
        end)
        |> Enum.sort_by(fn {entry, _needle} -> entry.name end)

      {:ok, entries}
    end
  end

  defp fetch_functions(node, module) do
    case Agent.call(node, :trace_functions, [module], @timeout) do
      {:ok, {:ok, functions}} ->
        entries =
          functions
          |> Enum.map(fn {name, arity, exported?} ->
            %{name: name, arity: arity, exported?: exported?}
          end)
          |> Enum.sort_by(&{&1.name, &1.arity})

        {:ok, entries}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_filter(nil), do: nil

  defp normalize_filter(filter) do
    case filter |> String.trim() |> String.downcase() do
      "" -> nil
      needle -> needle
    end
  end

  defp filter_modules(entries, nil), do: Enum.map(entries, &elem(&1, 0))

  defp filter_modules(entries, needle) do
    for {entry, name} <- entries, String.contains?(name, needle), do: entry
  end

  defp ttl_ms, do: Application.get_env(:voyager, :module_catalog_ttl_ms, @default_ttl_ms)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:node_connected, node}, state) do
    refresh(node)
    {:noreply, state}
  end

  def handle_info({event, node, _reason}, state) when event in [:node_disconnected, :nodedown] do
    refresh(node)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
