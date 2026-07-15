defmodule Voyager.Services.ProcessInfo do
  @moduledoc """
  Fetches runtime details for a single process on a remote node via `:erpc`.

  Backs the supervision tree process detail panel: overview, links, and
  memory/GC figures. All values are returned pre-formatted as display strings
  (and `links` as a list of strings) so callers can render them directly.
  """

  alias Voyager.Erpc

  @timeout 1_000

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
    :catchlevel,
    :links,
    :memory,
    :total_heap_size,
    :heap_size,
    :stack_size,
    :garbage_collection
  ]

  @type info :: %{
          initial_call: String.t(),
          current_function: String.t(),
          registered_name: String.t(),
          status: String.t(),
          message_queue_len: String.t(),
          group_leader: String.t(),
          priority: String.t(),
          trap_exit: String.t(),
          reductions: String.t(),
          catch_level: String.t(),
          links: [String.t()],
          memory: String.t(),
          stack_and_heaps: String.t(),
          heap_size: String.t(),
          stack_size: String.t(),
          gc_min_heap_size: String.t(),
          gc_fullsweep_after: String.t()
        }

  @doc """
  Fetches and formats process info for `pid` on `node`.

  Returns `{:error, :dead}` when the process is gone, `{:error, :not_a_pid}`
  for non-process nodes (apps, ports, references), or `{:error, reason}` on
  remote/transport failures.
  """
  @spec fetch(node(), pid() | nil) :: {:ok, info()} | {:error, term()}
  def fetch(node, pid) when is_pid(pid) do
    with {:ok, raw} when is_list(raw) <- call(node, :erlang, :process_info, [pid, @keys]),
         {:ok, word_size} <- call(node, :erlang, :system_info, [:wordsize]) do
      {:ok, format(Map.new(raw), word_size)}
    else
      {:ok, :undefined} -> {:error, :dead}
      {:error, _} = err -> err
    end
  end

  def fetch(_node, _pid), do: {:error, :not_a_pid}

  defp format(raw, word_size) do
    gc = Map.get(raw, :garbage_collection, [])

    %{
      initial_call: format_mfa(Map.get(raw, :initial_call)),
      current_function: format_mfa(Map.get(raw, :current_function)),
      registered_name: format_registered_name(Map.get(raw, :registered_name)),
      status: to_string(Map.get(raw, :status, :undefined)),
      message_queue_len: to_string(Map.get(raw, :message_queue_len, 0)),
      group_leader: format_identifier(Map.get(raw, :group_leader)),
      priority: to_string(Map.get(raw, :priority, :normal)),
      trap_exit: to_string(Map.get(raw, :trap_exit, false)),
      reductions: delimit(Map.get(raw, :reductions, 0)),
      catch_level: to_string(Map.get(raw, :catchlevel, 0)),
      links: raw |> Map.get(:links, []) |> Enum.map(&format_identifier/1),
      memory: format_bytes(Map.get(raw, :memory, 0)),
      stack_and_heaps: format_words(Map.get(raw, :total_heap_size, 0), word_size),
      heap_size: format_words(Map.get(raw, :heap_size, 0), word_size),
      stack_size: format_words(Map.get(raw, :stack_size, 0), word_size),
      gc_min_heap_size: format_words(Keyword.get(gc, :min_heap_size, 0), word_size),
      gc_fullsweep_after: to_string(Keyword.get(gc, :fullsweep_after, 0))
    }
  end

  defp format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp format_mfa(_), do: "—"

  defp format_registered_name(name) when is_atom(name) and not is_nil(name), do: inspect(name)
  defp format_registered_name(_), do: "—"

  defp format_identifier(pid) when is_pid(pid),
    do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp format_identifier(port) when is_port(port),
    do: port |> :erlang.port_to_list() |> List.to_string()

  defp format_identifier(other), do: inspect(other)

  defp format_words(words, word_size) when is_integer(words), do: format_bytes(words * word_size)
  defp format_words(_, _), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes < 1_024 -> "#{bytes} B"
      bytes < 1_048_576 -> "#{Float.round(bytes / 1_024, 1)} KiB"
      bytes < 1_073_741_824 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      true -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
    end
  end

  defp format_bytes(_), do: "—"

  defp delimit(int) when is_integer(int) do
    int
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp delimit(other), do: to_string(other)

  # Translates every `:erpc.call` failure into an `{:error, reason}` tuple so no
  # raw exception escapes to the caller.
  defp call(node, mod, fun, args) do
    {:ok, Erpc.call(node, mod, fun, args, @timeout)}
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    :error, {:erpc, :noconnection} -> {:error, :noconnection}
    :error, {:exception, reason, _stack} -> {:error, {:remote_exception, reason}}
    :error, {:erpc, _} = reason -> {:error, reason}
    :error, reason -> {:error, reason}
    :exit, reason -> {:error, {:remote_exit, reason}}
    :throw, value -> {:error, {:remote_throw, value}}
  end
end
