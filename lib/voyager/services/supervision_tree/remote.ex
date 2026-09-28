defmodule Voyager.Services.SupervisionTree.Remote do
  @moduledoc """
  Thin `:erpc` wrappers for remote node inspection of supervision tree.
  """

  alias Voyager.Erpc

  @timeout_fast 1_000
  @timeout_children 3_000
  @timeout_pinfo 2_000
  @base_process_info_keys [:registered_name, :initial_call, :current_function]
  @relations_process_info_keys [:links, :monitors, :monitored_by]

  @doc """
  Returns the list of OTP applications running on `node`.
  """
  @spec list_running_applications(node()) ::
          {:ok, [{atom(), charlist(), charlist()}]} | {:error, term()}
  def list_running_applications(node) do
    with {:ok, apps} <- Erpc.safe_call(node, :application, :which_applications, [], @timeout_fast),
         {:ok, masters} <- app_masters(node, Enum.map(apps, fn {a, _, _} -> a end)) do
      running_apps =
        apps
        |> Enum.zip(masters)
        |> Enum.filter(fn {_, master} -> master != :undefined end)
        |> Enum.map(fn {app, _} -> app end)

      {:ok, running_apps}
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
    Erpc.safe_call(
      node,
      :lists,
      :map,
      [&:application_controller.get_master/1, apps],
      @timeout_fast
    )
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
    Erpc.safe_call(
      node,
      :lists,
      :map,
      [&:application_master.get_child/1, master_pids],
      @timeout_fast
    )
  end

  @spec which_children(node(), pid()) ::
          {:ok,
           [
             {term(), pid() | :undefined | :restarting, :worker | :supervisor,
              :dynamic | [module()]}
           ]}
          | {:error, term()}
  def which_children(node, sup_pid) do
    Erpc.safe_call(node, :supervisor, :which_children, [sup_pid], @timeout_children)
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
    Erpc.safe_call(
      node,
      :lists,
      :map,
      [&:supervisor.which_children/1, sup_pids],
      @timeout_children
    )
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
    case Erpc.safe_call(node, :supervisor, :count_children, [sup_pid], @timeout_fast) do
      {:ok, counts} when is_list(counts) ->
        {:ok, Keyword.get(counts, :active, 0)}

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
    case Erpc.safe_call(
           node,
           :lists,
           :map,
           [&:supervisor.count_children/1, sup_pids],
           @timeout_fast
         ) do
      {:ok, counts_list} when is_list(counts_list) ->
        counts_list
        |> Enum.map(fn
          counts when is_list(counts) -> Keyword.get(counts, :active, 0)
          _ -> 0
        end)
        |> then(&{:ok, &1})

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Fetches `:process_info` for a batch of PIDs on `node` in a single `:erpc`
  call (see `process_info_many/3`). Returns a map keyed by PID; dead processes
  map to `:dead`.

  Always fetches the `@base_process_info_keys` (e.g. `:registered_name`). Pass
  `include_relations?: true` to additionally fetch the
  `@relations_process_info_keys` (`:links`, `:monitors`, `:monitored_by`),
  which are needed to build inter-process relation edges.

  ## Options

    * `:include_relations?` — when `true`, also fetch link/monitor relation
      keys. Defaults to `false`.
  """
  @spec process_info_batch(node(), [pid()], include_relations?: boolean()) ::
          {:ok, %{pid() => map() | :dead}} | {:error, term()}
  def process_info_batch(node, pids, opts \\ []) do
    if Keyword.get(opts, :include_relations?, false) do
      process_info_many(node, pids, @base_process_info_keys ++ @relations_process_info_keys)
    else
      process_info_many(node, pids, @base_process_info_keys)
    end
  end

  @doc """
  Fetches `:process_info` for `pids` on `node` with the given `keys` in one
  `:erpc` call.

  Runs `:lists.zipwith(&:erlang.process_info/2, pids, dup_keys)` on the remote —

  Returns a map keyed by PID; dead processes (`process_info/2` returns `:undefined`) map to `:dead`.
  """
  @spec process_info_many(node(), [pid()], [atom()]) ::
          {:ok, %{pid() => map() | :dead}} | {:error, term()}
  def process_info_many(_node, [], _keys), do: {:ok, %{}}

  def process_info_many(node, pids, keys) do
    dup_keys = List.duplicate(keys, length(pids))

    case Erpc.safe_call(
           node,
           :lists,
           :zipwith,
           [&:erlang.process_info/2, pids, dup_keys],
           @timeout_pinfo
         ) do
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
end
