defmodule Voyager.Services.Ets.Fetch do
  @moduledoc """
  Host-isolated ETS record reads.

  Runs `Remote.select_chunk/5` and `Remote.lookup/4` in a TaskSupervisor child
  with `max_heap_size` 500_000 words (`kill: true`), then sanitizes records
  (not the continuation). Heap kill is `{:error, :heap_limit_exceeded}`; a wait
  that expires is `{:error, :timeout}`. Protects Voyager, not the target: MFA
  peek still copies full objects on the remote node and over the wire.
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
end
