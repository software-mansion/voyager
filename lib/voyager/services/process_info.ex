defmodule Voyager.Services.ProcessInfo do
  @moduledoc """
  Fetches runtime details for a single process on a remote node via `:erpc`.

  Returns a structured `info` map with Erlang-native values (MFAs, pids, atoms,
  integers). Word-counted sizes from `:erlang.process_info/2` are converted to
  bytes using the remote node's word size; nothing else is formatted for display.
  """

  alias Voyager.Erpc

  @keys [
    :initial_call,
    :current_function,
    :registered_name,
    :status,
    :message_queue_len,
    :group_leader,
    :priority,
    :trap_exit,
    :reductions,
    :binary,
    :last_calls,
    :catchlevel,
    :trace,
    :suspending,
    :sequential_trace_token,
    :error_handler,
    :links,
    :memory,
    :total_heap_size,
    :heap_size,
    :stack_size,
    :garbage_collection
  ]

  @type info :: %{
          initial_call: mfa(),
          current_function: mfa(),
          registered_name: atom() | nil,
          status: :exiting | :garbage_collecting | :waiting | :running | :runnable | :suspended,
          message_queue_len: non_neg_integer(),
          group_leader: pid(),
          priority: :low | :normal | :high | :max,
          trap_exit: boolean(),
          reductions: non_neg_integer(),
          binary: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}],
          last_calls: [mfa()] | false,
          catch_level: non_neg_integer(),
          trace: non_neg_integer(),
          suspending: [{pid(), non_neg_integer(), non_neg_integer()}],
          sequential_trace_token: term() | nil,
          error_handler: module(),
          links: [pid() | port()],
          memory: non_neg_integer(),
          stack_and_heap_size: non_neg_integer(),
          heap_size: non_neg_integer(),
          stack_size: non_neg_integer(),
          gc_min_heap_size: non_neg_integer() | nil,
          gc_fullsweep_after: non_neg_integer() | nil
        }

  @doc """
  Fetches process info for `pid` on `node`.

  Returns `{:error, :dead}` when the process is gone, `{:error, :not_a_pid}`
  for non-process nodes (apps, ports, references), `{:error, :incomplete}` when
  essential fields are missing or malformed, or `{:error, reason}` on
  remote/transport failures.
  """
  @spec fetch(node(), pid() | nil) :: {:ok, info()} | {:error, term()}
  def fetch(node, pid) when is_pid(pid) do
    with {:ok, raw} when is_list(raw) <-
           Erpc.safe_call(node, :erlang, :process_info, [pid, @keys]),
         {:ok, word_size} when is_integer(word_size) and word_size > 0 <-
           Erpc.safe_call(node, :erlang, :system_info, [:wordsize]),
         {:ok, info} <- build(raw, word_size) do
      {:ok, info}
    else
      {:ok, :undefined} -> {:error, :dead}
      {:error, _} = err -> err
    end
  end

  def fetch(_node, _pid), do: {:error, :not_a_pid}

  defp build(raw, word_size) when is_list(raw) do
    info = Map.new(raw)
    gc = Map.get(info, :garbage_collection, [])

    try do
      info =
        info
        |> Map.put(:registered_name, registered_name(info))
        |> Map.put(:catch_level, info.catchlevel)
        |> Map.put(:sequential_trace_token, sequential_trace_token(info))
        |> Map.put(:stack_and_heap_size, info.total_heap_size * word_size)
        |> Map.put(:heap_size, info.heap_size * word_size)
        |> Map.put(:stack_size, info.stack_size * word_size)
        |> Map.put(:gc_min_heap_size, gc_min_heap_size(gc, word_size))
        |> Map.put(:gc_fullsweep_after, gc_fullsweep_after(gc))

      {:ok, info}
    catch
      :error, reason -> {:error, reason}
    end
  end

  defp registered_name(info) do
    case info.registered_name do
      [] -> nil
      name when is_atom(name) -> name
    end
  end

  defp sequential_trace_token(info) do
    case info.sequential_trace_token do
      [] -> nil
      token -> token
    end
  end

  defp gc_min_heap_size(gc, word_size) do
    case Keyword.fetch(gc, :min_heap_size) do
      {:ok, min_heap_size} -> min_heap_size * word_size
      _ -> nil
    end
  end

  defp gc_fullsweep_after(gc) do
    case Keyword.fetch(gc, :fullsweep_after) do
      {:ok, fullsweep_after} -> fullsweep_after
      _ -> nil
    end
  end
end
