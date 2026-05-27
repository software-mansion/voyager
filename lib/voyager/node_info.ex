defmodule Voyager.NodeInfo do
  @moduledoc """
  Public entry point for BEAM node introspection.

  `fetch/2` collects a `Voyager.NodeInfo.Snapshot` from any node reachable
  via `:erpc`. All RPC calls run concurrently and the target does not need
  Voyager installed.

  ## Options

    * `:timeout` — overall budget in milliseconds. Defaults to `5_000`.
  """

  alias Voyager.NodeInfo.Language
  alias Voyager.NodeInfo.Limits
  alias Voyager.NodeInfo.Memory
  alias Voyager.NodeInfo.Processors
  alias Voyager.NodeInfo.RunQueues
  alias Voyager.NodeInfo.Schedulers
  alias Voyager.NodeInfo.Snapshot
  alias Voyager.NodeInfo.Statistics
  alias Voyager.NodeInfo.SystemInfo

  @default_timeout 5_000

  @typedoc """
  Why a fetch failed.

    * `:noconnection` — the target node is unreachable.
    * `:timeout` — the fetch exceeded the configured `:timeout`.
    * `{:rpc, term()}` — `:erpc` failed for another reason
      (e.g. `:badrpc`, `:notsup`, remote exception).
    * `{:internal, String.t()}` — RPC succeeded but returned an
      unexpected shape; should not normally happen.
  """
  @type error_reason ::
          :noconnection
          | :timeout
          | {:rpc, term()}
          | {:internal, String.t()}

  @type fetch_result :: {:ok, Snapshot.t()} | {:error, error_reason()}

  @spec fetch(node(), keyword()) :: fetch_result()
  def fetch(node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, data} <- collect(node, timeout) do
      build_snapshot(node, data)
    end
  end

  defp build_snapshot(node, data) do
    snapshot = %Snapshot{
      node: node,
      collected_at: DateTime.utc_now(),
      system: SystemInfo.build(data.system_info),
      languages: Language.build(data.language_versions),
      memory: Memory.build(data.memory),
      runtime: Statistics.build(data.statistics),
      limits: Limits.build(data.system_info),
      processors: Processors.build(data.system_info),
      schedulers: Schedulers.build(data.system_info),
      run_queues: RunQueues.build(data.statistics)
    }

    {:ok, snapshot}
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  end

  defp collect(node, timeout) do
    system_info_keys =
      Enum.uniq(
        SystemInfo.system_info_keys() ++
          Limits.system_info_keys() ++
          Processors.system_info_keys() ++
          Schedulers.system_info_keys()
      )

    stat_keys = Enum.uniq(Statistics.statistics_keys() ++ RunQueues.statistics_keys())

    candidate_apps = Language.candidate_apps()

    base_funs = [
      fn -> :erpc.call(node, :lists, :map, [&:erlang.system_info/1, system_info_keys]) end,
      fn -> :erpc.call(node, :lists, :map, [&:erlang.statistics/1, stat_keys]) end,
      fn -> :erpc.call(node, :erlang, :memory, []) end
    ]

    language_funs =
      Enum.map(candidate_apps, fn app ->
        fn -> {app, :erpc.call(node, :application, :get_key, [app, :vsn])} end
      end)

    with {:ok, [system_info_values, stat_values, memory | language_versions]} <-
           run_parallel(base_funs ++ language_funs, timeout) do
      {:ok,
       %{
         system_info: system_info_keys |> Enum.zip(system_info_values) |> Map.new(),
         statistics: stat_keys |> Enum.zip(stat_values) |> Map.new(),
         memory: Map.new(memory),
         language_versions: language_versions
       }}
    end
  end

  defp run_parallel(funs, timeout) do
    tasks = Enum.map(funs, &safe_async/1)

    results = Task.yield_many(tasks, timeout)

    # Tasks that returned nil are still blocked on :erpc I/O; brutal_kill
    # guarantees immediate termination rather than waiting for the remote end.
    for {task, nil} <- results, do: Task.shutdown(task, :brutal_kill)

    summarize(results)
    |> dbg
  end

  defp safe_async(fun) do
    Task.async(fn ->
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:error, kind, reason}
      end
    end)
  end

  defp summarize(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {_task, {:ok, {:ok, value}}}, {:ok, acc} ->
        {:cont, {:ok, [value | acc]}}

      {_task, {:ok, {:error, kind, reason}}}, _ ->
        {:halt, {:error, classify(kind, reason)}}

      {_task, {:exit, reason}}, _ ->
        # Untrappable exit (e.g. task killed externally during shutdown).
        {:halt, {:error, {:rpc, reason}}}

      {_task, nil}, _ ->
        {:halt, {:error, :timeout}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp classify(:error, {:erpc, :noconnection}), do: :noconnection
  defp classify(_kind, reason), do: {:rpc, reason}
end
