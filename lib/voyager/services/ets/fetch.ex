defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Host-isolated ETS record reads.

  Runs `Remote.select_chunk/5`, `Remote.select_spec/6`, and `Remote.lookup/4`
  in a TaskSupervisor child with `max_heap_size` 500_000 words (`kill: true`
  and `include_shared_binaries: true`), then sanitizes records (not the
  continuation). Heap kill is `{:error, :heap_limit_exceeded}`; a wait that
  expires is `{:error, :timeout}`. A remote worker heap kill (`:killed`) is
  `{:error, :heap_limit_exceeded}` as well.

  The cap is this task's process heap (cons cells, maps, tuples) plus off-heap
  binaries it refers to, not host RSS. MFA peek still copies full objects on
  the remote node and over the wire; distribution allocates them before the
  task can be killed, then Sanitize keeps a 512-byte binary prefix. A page of
  large binaries can still OOM Voyager.
  """

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Remote
  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Services.Ets.TableId

  @max_heap_size 500_000
  @yield_slack 100

  @type chunk :: Remote.chunk()

  @spec select_chunk(node(), TableId.t(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_chunk(node, table, limit, continuation \\ nil, timeout \\ Erpc.default_timeout()) do
    isolated_read(timeout, fn ->
      Remote.select_chunk(node, table, limit, continuation, timeout)
    end)
  end

  @spec select_spec(node(), TableId.t(), term(), pos_integer(), term() | nil, timeout()) ::
          {:ok, chunk()} | {:error, term()}
  def select_spec(
        node,
        table,
        spec,
        limit,
        continuation \\ nil,
        timeout \\ Erpc.default_timeout()
      ) do
    isolated_read(timeout, fn ->
      Remote.select_spec(node, table, spec, limit, continuation, timeout)
    end)
  end

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
        {:error, _} = err -> map_remote_killed(err)
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

        Process.flag(:max_heap_size, %{
          size: @max_heap_size,
          kill: true,
          include_shared_binaries: true
        })

        fun.()
      end)

    case Task.yield(task, yield_timeout(timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        format_task_exit(reason)

      nil ->
        {:error, :timeout}
    end
  end

  # Probe + read each use `timeout`; the yield must outlast both.
  defp yield_timeout(:infinity), do: :infinity
  defp yield_timeout(timeout) when is_integer(timeout), do: timeout * 2 + @yield_slack

  defp format_task_exit(:killed), do: {:error, :heap_limit_exceeded}
  defp format_task_exit({:killed, _info}), do: {:error, :heap_limit_exceeded}
  defp format_task_exit(reason), do: {:error, {:task_exit, reason}}

  defp map_remote_killed({:error, {:remote_exception, :killed}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed({:error, {:remote_exception, {:killed, _}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed({:error, {:remote_exit, {:exception, :killed}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed({:error, {:remote_exit, {:exception, {:killed, _}}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed({:error, {:remote_exit, {:signal, :killed}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed({:error, {:remote_exit, {:signal, {:killed, _}}}}),
    do: {:error, :heap_limit_exceeded}

  defp map_remote_killed(err), do: err
end
