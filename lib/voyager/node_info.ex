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

  1. `:lists.map(&:erlang.system_info/1, all_si_keys)` — one server-side
     application of `:erlang.system_info/1` per unique key, regardless
     of how many submodules consume that key. Keys are deduplicated.
  2. `:lists.map(&:erlang.statistics/1, all_stat_keys)` — same shape for
     `:erlang.statistics/1`.
  3. `:erlang.memory/0`.
  4. `:application.loaded_applications/0`.

  The four calls run concurrently, so a whole snapshot costs ~1 network
  round trip against a remote node regardless of how many keys are
  sampled.

  The function is stateless; callers that need rates (e.g. reductions
  per second) should retain the previous snapshot and diff against it.
  """

  alias Voyager.NodeInfo.{Limits, Memory, Runtime, Snapshot}
  alias Voyager.NodeInfo.System, as: SystemInfo

  @fetch_timeout 5_000

  @type fetch_error :: {kind :: atom(), reason :: term()}

  @spec fetch(node(), keyword()) :: {:ok, Snapshot.t()} | {:error, fetch_error()}
  def fetch(node \\ Node.self(), _opts \\ []) do
    data = collect(node, @fetch_timeout)

    snapshot = %Snapshot{
      node: node,
      collected_at: DateTime.utc_now(),
      system: SystemInfo.build(data.system_info),
      memory: Memory.build(data.memory),
      runtime: Runtime.build(data.statistics),
      limits: Limits.build(data.system_info),
      voyager_version: voyager_version()
    }

    {:ok, snapshot}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Version of the Voyager application itself (the introspector), read
  from the local `:voyager` app spec. Returns `"unknown"` if unavailable.
  """
  @spec voyager_version() :: String.t()
  def voyager_version do
    case :application.get_key(:voyager, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "unknown"
    end
  end

  defp collect(node, timeout) do
    si_keys = Enum.uniq(SystemInfo.system_info_keys() ++ Limits.system_info_keys())
    stat_keys = Runtime.statistics_keys()

    [si_values, stat_values, memory] =
      [
        fn -> :erpc.call(node, :lists, :map, [&:erlang.system_info/1, si_keys]) end,
        fn -> :erpc.call(node, :lists, :map, [&:erlang.statistics/1, stat_keys]) end,
        fn -> :erpc.call(node, :erlang, :memory, []) end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(timeout)

    %{
      system_info: si_keys |> Enum.zip(si_values) |> Map.new(),
      statistics: stat_keys |> Enum.zip(stat_values) |> Map.new(),
      memory: memory |> Map.new()
    }
  end
end
