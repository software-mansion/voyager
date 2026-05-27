defmodule Voyager.Queries.SupervisionTree.Remote do
  @moduledoc """
  Thin, safe `:erpc` wrappers for remote node inspection.

  BIF-only: no helper module is loaded on the remote node. Every function
  returns `{:ok, value} | {:error, reason}` and never lets raw `:erpc`
  exceptions escape to callers.
  """

  @timeout_fast 500
  @timeout_children 1_500
  @timeout_pinfo 1_000
  @pinfo_chunk_size 32
  @safe_pinfo_keys [
    :registered_name,
    :initial_call,
    :current_function,
    :status,
    :memory,
    :message_queue_len,
    :reductions
  ]

  @doc """
  Returns the list of OTP applications running on `node`.

  Calls `:application.which_applications/0` via `:erpc`.
  """
  @spec list_applications(node()) ::
          {:ok, [{atom(), charlist(), charlist()}]} | {:error, term()}
  def list_applications(node) do
    call(node, :application, :which_applications, [], @timeout_fast)
  end

  @doc """
  Returns the root supervisor PID for `app` on `node`.

  Returns `{:error, :not_running}` if the app is not started.
  """
  @spec root_supervisor(node(), atom()) :: {:ok, pid()} | {:error, :not_running | term()}
  def root_supervisor(node, app) do
    with {:ok, master_pid} <- get_master(node, app) do
      get_child(node, master_pid)
    end
  end

  @doc """
  Returns the children of `sup_pid` on `node` via `:supervisor.which_children/1`.
  """
  @spec which_children(node(), pid()) ::
          {:ok,
           [
             {term(), pid() | :undefined | :restarting, :worker | :supervisor,
              :dynamic | [module()]}
           ]}
          | {:error, term()}
  def which_children(node, sup_pid) do
    call(node, :supervisor, :which_children, [sup_pid], @timeout_children)
  end

  @doc """
  Returns the spec-children count for `sup_pid` on `node` via
  `:supervisor.count_children/1`.

  Cheaper than `which_children/2` when only the count is needed — used for
  collapsed/stub supervisors so the UI can show a `(N)` badge.
  """
  @spec count_children(node(), pid()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_children(node, sup_pid) do
    case call(node, :supervisor, :count_children, [sup_pid], @timeout_fast) do
      {:ok, counts} when is_list(counts) ->
        {:ok, Keyword.get(counts, :specs, 0)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Fetches `:process_info` for a batch of PIDs on `node`.

  Splits `pids` into chunks of `@pinfo_chunk_size` and issues one
  `:erpc.call(node, :erlang, :process_info, [pid, keys])` per PID via local
  `Task.async_stream`, bounding concurrency. Returns a map keyed by PID;
  dead processes map to `:dead`. If any chunk fails the whole call returns
  `{:error, reason}`.
  """
  @spec process_info_batch(node(), [pid()]) :: {:ok, %{pid() => map() | :dead}} | {:error, term()}
  def process_info_batch(node, pids) do
    chunks = Enum.chunk_every(pids, @pinfo_chunk_size)

    result =
      Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, acc} ->
        case fetch_pinfo_chunk(node, chunk) do
          {:ok, chunk_map} -> {:cont, {:ok, Map.merge(acc, chunk_map)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_master(node, app) do
    case call(node, :application_controller, :get_master, [app], @timeout_fast) do
      {:ok, :undefined} -> {:error, :not_running}
      {:ok, pid} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  defp get_child(node, master_pid) do
    case call(node, :application_master, :get_child, [master_pid], @timeout_fast) do
      {:ok, {child_pid, _app_module}} -> {:ok, child_pid}
      {:ok, child_pid} when is_pid(child_pid) -> {:ok, child_pid}
      {:error, _} = err -> err
    end
  end

  defp fetch_pinfo_chunk(node, pids) do
    results =
      Task.async_stream(
        pids,
        fn pid ->
          call(node, :erlang, :process_info, [pid, @safe_pinfo_keys], @timeout_pinfo)
        end,
        timeout: @timeout_pinfo + 200,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while([], fn
        {:ok, {:ok, result}}, acc -> {:cont, [result | acc]}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, reason}}
      end)

    case results do
      {:error, _} = err ->
        err

      pinfo_list ->
        map =
          Enum.zip(pids, Enum.reverse(pinfo_list))
          |> Map.new(fn
            {pid, :undefined} -> {pid, :dead}
            {pid, kw_list} -> {pid, Map.new(kw_list)}
          end)

        {:ok, map}
    end
  end

  defp call(node, mod, fun, args, timeout) do
    result = :erpc.call(node, mod, fun, args, timeout)
    {:ok, result}
  catch
    :error, {:erpc, :timeout} ->
      {:error, :timeout}

    :error, {:erpc, :noconnection} ->
      {:error, :not_connected}

    :error, {:exception, reason, _stack} ->
      {:error, {:remote_exception, reason}}

    :error, {:erpc, _} = reason ->
      {:error, reason}
  end
end
