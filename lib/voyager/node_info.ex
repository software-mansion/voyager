defmodule Voyager.NodeInfo do
  @moduledoc """
  Public entry point for BEAM node introspection.

  `fetch/2` builds a `Voyager.NodeInfo.Snapshot` against a target node.
  The default target is `Node.self()`; any `node()` reachable via
  `:erpc` works. Fetchers only call OTP stdlib modules (`:erlang`,
  `:application`, `:lists`), so the target does not need Voyager
  installed.

  The submodules under `Voyager.NodeInfo.*` are passive — each declares
  the keys it needs (`system_info_keys/0`, `statistics_keys/0`) and a
  pure `build/N` that turns pre-fetched data into its struct. This
  module owns all RPC and runs four concurrent `:erpc.call/4`s per
  snapshot:

  1. `:lists.map(&:erlang.system_info/1, all_system_info_keys)` — one server-side
     application of `:erlang.system_info/1` per unique key, regardless
     of how many submodules consume that key. Keys are deduplicated.
  2. `:lists.map(&:erlang.statistics/1, all_stat_keys)` — same shape for
     `:erlang.statistics/1`.
  3. `:erlang.memory/0`.
  4. One `:application.get_key(app, :vsn)` per
     `Language.candidate_apps/0` entry. Each returns `{:ok, vsn}` or
     `:undefined` (~30 bytes on the wire), so the language-detection
     payload stays minimal and the snapshot has no side effects on
     the target node.

  The four tasks run concurrently, so a whole snapshot costs ~1 network
  round trip against a remote node regardless of how many keys are
  sampled.
  """

  alias Voyager.NodeInfo.{
    Language,
    Limits,
    Memory,
    Processors,
    RunQueues,
    Schedulers,
    Statistics,
    Snapshot,
    SystemInfo
  }

  @fetch_timeout 5_000

  @type fetch_error :: {kind :: atom(), reason :: term()}

  @spec fetch(node(), keyword()) :: {:ok, Snapshot.t()} | {:error, fetch_error()}
  def fetch(node \\ Node.self(), _opts \\ []) do
    data = collect(node, @fetch_timeout)

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
  catch
    kind, reason -> {:error, {kind, reason}}
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

    [system_info_values, stat_values, memory, language_versions] =
      [
        fn -> :erpc.call(node, :lists, :map, [&:erlang.system_info/1, system_info_keys]) end,
        fn -> :erpc.call(node, :lists, :map, [&:erlang.statistics/1, stat_keys]) end,
        fn -> :erpc.call(node, :erlang, :memory, []) end,
        fn ->
          Enum.map(candidate_apps, fn app ->
            {app, :erpc.call(node, :application, :get_key, [app, :vsn])}
          end)
        end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(timeout)

    %{
      system_info: system_info_keys |> Enum.zip(system_info_values) |> Map.new(),
      statistics: stat_keys |> Enum.zip(stat_values) |> Map.new(),
      memory: memory |> Map.new(),
      language_versions: language_versions
    }
  end
end
