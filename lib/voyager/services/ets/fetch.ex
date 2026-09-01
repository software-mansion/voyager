defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Host-isolated ETS record reads.

  Runs `Remote.select_chunk/5` and `Remote.lookup/4` in a
  `Task.Supervisor.async_nolink/2` child with `max_heap_size` 500_000 words
  (`kill: true`), then sanitizes **records** (not the continuation) before
  they reach the caller. A heap kill during the wait becomes
  `{:error, :heap_limit_exceeded}`. A wait that expires is `{:error, :timeout}`.

  This protects Voyager, not the target. MFA peek still copies full objects
  on the remote node and over the wire.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Services.Ets.TableId

  @max_heap_size 500_000

  @type chunk :: Remote.chunk()

  @doc """
  Match-all page of sanitized records from `table` on `node`.

  `limit` must be 10, 20, or 50 (10 is the usual first page). `continuation`
  is `nil` for the first page and the opaque ETS term from a prior chunk
  afterwards — callers (LiveView) bind it to `{node, table_id}`, not a URL
  token.
  """
  @spec select_chunk(node(), TableId.t(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(node, table, limit, continuation \\ nil, timeout \\ Erpc.default_timeout()) do
    isolated_read(timeout, fn ->
      Remote.select_chunk(node, table, limit, continuation, timeout)
    end)
  end

  @doc """
  Looks up `key` on `table` and sanitizes the matching records.
  """
  @spec lookup(node(), TableId.t(), atom() | integer() | binary(), timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def lookup(node, table, key, timeout \\ Erpc.default_timeout()) do
    isolated_read(timeout, fn ->
      Remote.lookup(node, table, key, timeout)
    end)
  end

  defp isolated_read(timeout, fun) do
    isolate(timeout, fn ->
      case fun.() do
        {:ok, chunk} -> {:ok, sanitize_chunk(chunk)}
        {:error, _} = err -> err
      end
    end)
  end

  defp sanitize_chunk(%{records: records} = chunk) do
    %{chunk | records: Enum.map(records, &Sanitize.term/1)}
  end

  defp isolate(timeout, fun) do
    impl = Erpc.impl()

    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        Erpc.bind_impl(impl)
        Process.flag(:max_heap_size, %{size: @max_heap_size, kill: true})
        fun.()
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        format_task_exit(reason)

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp format_task_exit(:killed), do: {:error, :heap_limit_exceeded}
  defp format_task_exit({:killed, _info}), do: {:error, :heap_limit_exceeded}
  defp format_task_exit(reason), do: {:error, {:task_exit, reason}}
end
