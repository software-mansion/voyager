defmodule Voyager.Services.ProcessInfo do
  @moduledoc """
  Fetches runtime details for a single process on a remote node via `:erpc`.

  `fetch/2` reads `:erlang.process_info/2` directly and returns only fixed-size
  attributes, so it is safe to call eagerly on every refresh. Unbounded
  attributes are excluded from it and exposed as separate `fetch_*/3` functions,
  which go through `:voyager_agent` on the remote node so the payload is capped
  and truncated *before* it crosses the distribution channel; each returns a
  `bounded/1` map carrying the real `:total` alongside the truncated `:items`.
  Missing agent surfaces as `{:error, {:remote_exception, :undef}}`.

  The process dictionary is not read by `fetch/2` at all, so `:initial_call` is
  the raw one — for an OTP-behaviour process its `proc_lib` entry point, not the
  spawn MFA recorded under `$initial_call`.

  Returns a structured `info` map with Erlang-native values (MFAs, pids, atoms,
  integers). Word-counted sizes from `:erlang.process_info/2` are converted to
  bytes using the remote node's word size; nothing else is formatted for display.
  """

  alias Voyager.Agent
  alias Voyager.Erpc

  # Default `:erpc` timeout for every fetch; each takes it as a trailing
  # argument so a caller on a slow link can override it.
  @timeout 5_000

  @keys [
    :initial_call,
    :current_function,
    :current_stacktrace,
    :registered_name,
    :label,
    :parent,
    :status,
    :message_queue_len,
    :message_queue_data,
    :group_leader,
    :priority,
    :trap_exit,
    :reductions,
    :last_calls,
    :catchlevel,
    :trace,
    :suspending,
    :sequential_trace_token,
    :error_handler,
    :memory,
    :total_heap_size,
    :heap_size,
    :stack_size,
    :garbage_collection
  ]

  @typedoc """
  A remote-truncated view of an unbounded attribute. `:total` is the real length
  on the remote node, `:items` holds at most the requested limit, and
  `:truncated?` says whether anything was dropped.
  """
  @type bounded(item) :: %{
          total: non_neg_integer(),
          truncated?: boolean(),
          items: [item]
        }

  @type monitor ::
          {:process, pid() | {atom(), node()}}
          | {:port, port()}

  @type dictionary_entry :: {term(), term()}

  @type info :: %{
          initial_call: mfa(),
          current_function: mfa(),
          current_stacktrace: [{module(), atom(), arity(), keyword()}],
          registered_name: atom() | nil,
          label: term() | nil,
          parent: pid() | nil,
          status: :exiting | :garbage_collecting | :waiting | :running | :runnable | :suspended,
          message_queue_len: non_neg_integer(),
          message_queue_data: :off_heap | :on_heap,
          group_leader: pid(),
          priority: :low | :normal | :high | :max,
          trap_exit: boolean(),
          reductions: non_neg_integer(),
          last_calls: [mfa()] | false,
          catch_level: non_neg_integer(),
          trace: non_neg_integer(),
          suspending: [{pid(), non_neg_integer(), non_neg_integer()}],
          sequential_trace_token: term() | nil,
          error_handler: module(),
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
  for non-process nodes (apps, ports, references), or `{:error, reason}` on
  remote/transport failures.
  """
  @spec fetch(node(), pid() | nil, timeout()) :: {:ok, info()} | {:error, term()}
  def fetch(node, pid, timeout \\ @timeout)

  def fetch(node, pid, timeout) when is_pid(pid) do
    with {:ok, raw} when is_list(raw) <- call(node, :erlang, :process_info, [pid, @keys], timeout),
         {:ok, word_size} when is_integer(word_size) and word_size > 0 <-
           call(node, :erlang, :system_info, [:wordsize], timeout),
         {:ok, info} <- build(raw, word_size) do
      {:ok, info}
    else
      {:ok, :undefined} -> {:error, :dead}
      {:error, _} = err -> err
    end
  end

  def fetch(_node, _pid, _timeout), do: {:error, :not_a_pid}

  @doc """
  Fetches the current link set for `pid` on `node`, truncated on the remote to
  at most `limit` entries.

  `:links` is unbounded, hence the separate call and explicit `limit`. Safe to
  fetch eagerly; pass a `limit` no larger than what you can render.
  """
  @spec fetch_links(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, bounded(pid() | port())} | {:error, term()}
  def fetch_links(node, pid, limit, timeout \\ @timeout)

  def fetch_links(node, pid, limit, timeout)
      when is_pid(pid) and is_integer(limit) and limit >= 0 do
    agent_fetch(node, :proc_links, [pid, limit], timeout)
  end

  def fetch_links(_node, _pid, _limit, _timeout), do: {:error, :not_a_pid}

  @doc """
  Fetches the monitors `pid` holds on `node`, truncated on the remote to at most
  `limit` entries.

  Entries arrive as raw `:erlang.process_info/2` monitor terms
  (`{:process, pid | {name, node}}`, `{:port, port}`).
  """
  @spec fetch_monitors(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, bounded(monitor())} | {:error, term()}
  def fetch_monitors(node, pid, limit, timeout \\ @timeout)

  def fetch_monitors(node, pid, limit, timeout)
      when is_pid(pid) and is_integer(limit) and limit >= 0 do
    agent_fetch(node, :proc_monitors, [pid, limit], timeout)
  end

  def fetch_monitors(_node, _pid, _limit, _timeout), do: {:error, :not_a_pid}

  @doc """
  Fetches the processes and ports monitoring `pid` on `node`, truncated on the
  remote to at most `limit` entries.
  """
  @spec fetch_monitored_by(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, bounded(pid() | port())} | {:error, term()}
  def fetch_monitored_by(node, pid, limit, timeout \\ @timeout)

  def fetch_monitored_by(node, pid, limit, timeout)
      when is_pid(pid) and is_integer(limit) and limit >= 0 do
    agent_fetch(node, :proc_monitored_by, [pid, limit], timeout)
  end

  def fetch_monitored_by(_node, _pid, _limit, _timeout), do: {:error, :not_a_pid}

  @doc """
  Fetches the process dictionary of `pid` on `node`, truncated on the remote to
  at most `limit` entries.

  Entries arrive as raw `{key, value}` terms. Only the entry count is bounded;
  an individual term can be large, which the agent's `max_heap_size` cap is
  there to survive.
  """
  @spec fetch_dictionary(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, bounded(dictionary_entry())} | {:error, term()}
  def fetch_dictionary(node, pid, limit, timeout \\ @timeout)

  def fetch_dictionary(node, pid, limit, timeout)
      when is_pid(pid) and is_integer(limit) and limit >= 0 do
    agent_fetch(node, :proc_dictionary, [pid, limit], timeout)
  end

  def fetch_dictionary(_node, _pid, _limit, _timeout), do: {:error, :not_a_pid}

  # The agent replies {:ok, payload} | {:error, :dead}, and `Agent.call/4` wraps
  # that in its own {:ok, _} | {:error, _}. Flatten both layers, and rename
  # `truncated` to the `truncated?` boolean convention used on this side.
  defp agent_fetch(node, fun, args, timeout) do
    case Agent.call(node, fun, args, timeout) do
      {:ok, {:ok, %{total: total, truncated: truncated, items: items}}} ->
        {:ok, %{total: total, truncated?: truncated, items: items}}

      {:ok, {:error, :dead}} ->
        {:error, :dead}

      {:error, _} = err ->
        err
    end
  end

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
        |> Map.put(:label, undefined_to_nil(info.label))
        |> Map.put(:parent, undefined_to_nil(info.parent))

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

  defp undefined_to_nil(:undefined), do: nil
  defp undefined_to_nil(value), do: value

  # Translates every `:erpc.call` failure into an `{:error, reason}` tuple so no
  # raw exception escapes to the caller.
  defp call(node, mod, fun, args, timeout) do
    {:ok, Erpc.call(node, mod, fun, args, timeout)}
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
