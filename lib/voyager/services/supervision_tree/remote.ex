defmodule Voyager.Services.SupervisionTree.Remote do
  @moduledoc """
  Thin, safe `:erpc` wrappers for remote node inspection.

  BIF-only: no helper module is loaded on the remote node. Every function
  returns `{:ok, value} | {:error, reason}` and never lets raw `:erpc`
  exceptions escape to callers.
  """

  @timeout_fast 500
  @timeout_children 1_500
  @timeout_pinfo 1_000
  @safe_pinfo_keys [
    :registered_name,
    :links,
    :monitors,
    :monitored_by
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
  Returns the application master PID and the application's root supervisor PID
  for `app` on `node`, as `{:ok, master_pid, root_supervisor_pid}`.

  The application master is the `:application_master` process returned by
  `:application_controller.get_master/1`; the root supervisor is the child it
  reports via `:application_master.get_child/1`.

  Returns `{:error, :not_running}` if the app is not started.
  """
  @spec app_root_chain(node(), atom()) ::
          {:ok, pid(), pid()} | {:error, :not_running | term()}
  def app_root_chain(node, app) do
    with {:ok, master_pid} <- get_master(node, app),
         {:ok, root_pid} <- get_child(node, master_pid) do
      {:ok, master_pid, root_pid}
    end
  end

  @doc """
  Returns the `$ancestors` recorded in `pid`'s process dictionary on `node`.
  """
  @spec ancestors(node(), pid()) :: {:ok, [pid() | atom()]} | {:error, term()}
  def ancestors(node, pid) do
    case call(node, :erlang, :process_info, [pid, :dictionary], @timeout_fast) do
      {:ok, {:dictionary, dict}} when is_list(dict) ->
        {:ok, Keyword.get(dict, :"$ancestors", [])}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns the application master PIDs for `apps` on `node` in one `:erpc` call.

  Runs `:lists.map(&:application_controller.get_master/1, apps)` on the remote,
  so the result list is positionally aligned with `apps`. Apps that are not
  running map to `:undefined`.
  """
  @spec app_masters(node(), [atom()]) :: {:ok, [pid() | :undefined]} | {:error, term()}
  def app_masters(_node, []), do: {:ok, []}

  def app_masters(node, apps) do
    call(node, :lists, :map, [&:application_controller.get_master/1, apps], @timeout_fast)
  end

  @doc """
  Returns the root child for each application master in `master_pids` on `node`
  in one `:erpc` call via `:lists.map(&:application_master.get_child/1, …)`.

  Each element is `{root_pid, app_module}` (or, on older systems, a bare
  `root_pid`), positionally aligned with `master_pids`.
  """
  @spec app_children(node(), [pid()]) ::
          {:ok, [{pid(), module()} | pid()]} | {:error, term()}
  def app_children(_node, []), do: {:ok, []}

  def app_children(node, master_pids) do
    call(node, :lists, :map, [&:application_master.get_child/1, master_pids], @timeout_fast)
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
  Returns the children of every supervisor in `sup_pids` on `node` in one
  `:erpc` call via `:lists.map(&:supervisor.which_children/1, sup_pids)`.

  The result list is positionally aligned with `sup_pids`. Because the remote
  `:lists.map` aborts if any single `which_children` raises (e.g. a supervisor
  died mid-walk), callers should fall back to per-pid `which_children/2` on
  `{:error, {:remote_exception, _}}` to isolate the offending pid.
  """
  @spec which_children_many(node(), [pid()]) :: {:ok, [list()]} | {:error, term()}
  def which_children_many(_node, []), do: {:ok, []}

  def which_children_many(node, sup_pids) do
    call(node, :lists, :map, [&:supervisor.which_children/1, sup_pids], @timeout_children)
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
  Returns the spec-children count for every supervisor in `sup_pids` on `node`
  in one `:erpc` call via `:lists.map(&:supervisor.count_children/1, sup_pids)`.

  The result list is positionally aligned with `sup_pids`. As with
  `which_children_many/2`, callers should fall back to per-pid `count_children/2`
  on `{:error, {:remote_exception, _}}`.
  """
  @spec count_children_many(node(), [pid()]) ::
          {:ok, [non_neg_integer()]} | {:error, term()}
  def count_children_many(_node, []), do: {:ok, []}

  def count_children_many(node, sup_pids) do
    case call(node, :lists, :map, [&:supervisor.count_children/1, sup_pids], @timeout_fast) do
      {:ok, counts_list} when is_list(counts_list) ->
        {:ok, Enum.map(counts_list, &Keyword.get(&1, :specs, 0))}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Fetches the `@safe_pinfo_keys` `:process_info` for a batch of PIDs on `node`
  in a single `:erpc` call (see `process_info_many/3`). Returns a map keyed by
  PID; dead processes map to `:dead`.
  """
  @spec process_info_batch(node(), [pid()]) :: {:ok, %{pid() => map() | :dead}} | {:error, term()}
  def process_info_batch(node, pids) do
    process_info_many(node, pids, @safe_pinfo_keys)
  end

  @doc """
  Fetches `:process_info` for `pids` on `node` with the given `keys` in one
  `:erpc` call.

  Runs `:lists.zipwith(&:erlang.process_info/2, pids, dup_keys)` on the remote —
  an external fun, so no helper code is shipped — collapsing what would be one
  call per PID into a single round-trip. Returns a map keyed by PID; dead
  processes (`process_info/2` returns `:undefined`) map to `:dead`.
  """
  @spec process_info_many(node(), [pid()], [atom()]) ::
          {:ok, %{pid() => map() | :dead}} | {:error, term()}
  def process_info_many(_node, [], _keys), do: {:ok, %{}}

  def process_info_many(node, pids, keys) do
    dup_keys = List.duplicate(keys, length(pids))

    case call(node, :lists, :zipwith, [&:erlang.process_info/2, pids, dup_keys], @timeout_pinfo) do
      {:ok, pinfo_list} when is_list(pinfo_list) ->
        map =
          pids
          |> Enum.zip(pinfo_list)
          |> Map.new(fn
            {pid, :undefined} -> {pid, :dead}
            {pid, kw_list} -> {pid, Map.new(kw_list)}
          end)

        {:ok, map}

      {:error, _} = err ->
        err
    end
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
