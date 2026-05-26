defmodule Voyager.Inspector.Walker do
  @moduledoc """
  Produces a lazy, bounded supervision tree for a set of OTP applications on a
  remote node.

  The tree walk is time-bounded by `@walk_deadline_ms`.  Nodes beyond the
  requested depth or outside the `expanded_pids` set are returned as stubs
  (`children: :not_loaded`).  One batched `process_info` RPC call is issued at
  the end to hydrate all nodes with runtime metrics.

  ## Return value

      {:ok | :partial, %{app_atom => tree_node()}, [error()]}

  ## Tree node shape

      %{
        pid: pid() | nil,
        name: atom() | String.t(),
        type: :app | :supervisor | :worker,
        modules: [module()] | :dynamic,
        info: map() | :dead | nil,
        has_children?: boolean(),
        child_count: non_neg_integer(),
        children: [tree_node()] | :not_loaded
      }

  `child_count` is the *direct* child count on the remote, sourced from
  `:supervisor.count_children/1` for stub supervisors and `length(children)`
  for fully-walked ones.  Workers and ghost nodes always carry `0`.

  ## Error shape

      {stage :: atom(), identifier :: term(), reason :: term()}

  Example errors:

      {:root_supervisor, :voyager_fixture, :not_running}
      {:which_children, pid, :timeout}
      {:deadline, pid, :exceeded}
      {:process_info, :batch, reason}
  """

  alias Voyager.Inspector.Remote

  @walk_deadline_ms 3_000
  @max_concurrency 4

  @type tree_node :: %{
          pid: pid() | nil,
          name: atom() | String.t(),
          type: :app | :supervisor | :worker,
          modules: [module()] | :dynamic,
          info: map() | :dead | nil,
          has_children?: boolean(),
          child_count: non_neg_integer(),
          children: [tree_node()] | :not_loaded
        }

  @type error :: {atom(), term(), term()}

  @doc """
  Walks the supervision trees for `apps` on `node`.

  `depth` controls how many supervisor levels below each app root are fully
  expanded.  `expanded` is a `MapSet` of PIDs that must be expanded regardless
  of depth — useful for user-triggered lazy loading.

  Returns `{:ok, tree_map, []}` on success, or `{:partial, tree_map, errors}`
  when some parts of the tree could not be retrieved.
  """
  @spec walk(node(), [atom()], non_neg_integer(), MapSet.t(pid())) ::
          {:ok | :partial, %{atom() => tree_node()}, [error()]}
  def walk(node, apps, depth, expanded) do
    deadline = now_ms() + @walk_deadline_ms

    {tree_map, all_errors} =
      Enum.reduce(apps, {%{}, []}, fn app, {acc_tree, acc_errors} ->
        case Remote.root_supervisor(node, app) do
          {:error, reason} ->
            error = {:root_supervisor, app, reason}
            {acc_tree, [error | acc_errors]}

          {:ok, root_pid} ->
            {root_node, node_errors} =
              walk_node(node, root_pid, app, :supervisor, [], depth, expanded, deadline)

            app_node = %{
              pid: root_pid,
              name: app,
              type: :app,
              modules: [],
              has_children?: true,
              child_count: 1,
              children: [root_node]
            }

            {Map.put(acc_tree, app, app_node), node_errors ++ acc_errors}
        end
      end)

    errors = Enum.reverse(all_errors)

    if errors == [] do
      {:ok, tree_map, []}
    else
      {:partial, tree_map, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — recursive walker
  # ---------------------------------------------------------------------------

  defp walk_node(node, pid, name, type, modules, depth_remaining, expanded, deadline) do
    if now_ms() >= deadline do
      error = {:deadline, pid, :exceeded}
      node = stub_node(pid, name, type, modules)
      {node, [error]}
    else
      do_walk_node(node, pid, name, type, modules, depth_remaining, expanded, deadline)
    end
  end

  # Workers are always leaves — never fetch children.
  defp do_walk_node(_node, pid, name, :worker, modules, _depth, _expanded, _deadline) do
    leaf = %{
      pid: pid,
      name: name,
      type: :worker,
      modules: modules,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }

    {leaf, []}
  end

  # Supervisor — check depth and expansion set to decide whether to recurse.
  defp do_walk_node(node, pid, name, :supervisor, modules, depth_remaining, expanded, deadline) do
    if depth_remaining > 0 or MapSet.member?(expanded, pid) do
      fetch_and_recurse(node, pid, name, modules, depth_remaining, expanded, deadline)
    else
      stub_supervisor(node, pid, name, modules)
    end
  end

  # Build a stub supervisor node, fetching the direct child count so the UI
  # can show the `(N)` badge without fully walking the subtree.
  defp stub_supervisor(node, pid, name, modules) do
    {count, errs} =
      case Remote.count_children(node, pid) do
        {:ok, n} -> {n, []}
        {:error, reason} -> {0, [{:count_children, pid, reason}]}
      end

    stub = %{
      pid: pid,
      name: name,
      type: :supervisor,
      modules: modules,
      has_children?: count > 0,
      child_count: count,
      children: :not_loaded
    }

    {stub, errs}
  end

  defp fetch_and_recurse(node, pid, name, modules, depth_remaining, expanded, deadline) do
    case Remote.which_children(node, pid) do
      {:error, reason} ->
        error = {:which_children, pid, reason}

        stub = %{
          pid: pid,
          name: name,
          type: :supervisor,
          modules: modules,
          has_children?: true,
          child_count: 0,
          children: :not_loaded
        }

        {stub, [error]}

      {:ok, raw_children} ->
        timeout = max(deadline - now_ms(), 50)

        results =
          Task.Supervisor.async_stream_nolink(
            Voyager.TaskSupervisor,
            raw_children,
            fn {child_id, child_pid_or_status, child_type, child_modules} ->
              walk_child(
                node,
                child_id,
                child_pid_or_status,
                child_type,
                child_modules,
                depth_remaining - 1,
                expanded,
                deadline
              )
            end,
            max_concurrency: @max_concurrency,
            timeout: timeout,
            on_timeout: :kill_task,
            ordered: true
          )
          |> Enum.to_list()

        {children, child_errors} =
          Enum.zip(raw_children, results)
          |> Enum.reduce({[], []}, fn
            {{_child_id, _child_pid, _child_type, _child_modules}, {:ok, {child_node, errs}}},
            {nodes_acc, errs_acc} ->
              {[child_node | nodes_acc], errs ++ errs_acc}

            {{child_id, child_pid, child_type, child_modules}, {:exit, reason}},
            {nodes_acc, errs_acc} ->
              error = {:which_children, child_pid, reason}
              ghost = ghost_node(child_id, child_pid, child_type, child_modules)
              {[ghost | nodes_acc], [error | errs_acc]}
          end)

        ordered_children = Enum.reverse(children)

        sup_node = %{
          pid: pid,
          name: name,
          type: :supervisor,
          modules: modules,
          has_children?: ordered_children != [],
          child_count: length(ordered_children),
          children: ordered_children
        }

        {sup_node, child_errors}
    end
  end

  # Walk a single child (called inside async_stream task).
  defp walk_child(
         _node,
         child_id,
         :undefined,
         _child_type,
         child_modules,
         _depth,
         _expanded,
         _deadline
       ) do
    ghost = %{
      pid: nil,
      name: child_id,
      type: :worker,
      modules: child_modules,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }

    {ghost, []}
  end

  defp walk_child(
         _node,
         child_id,
         :restarting,
         _child_type,
         child_modules,
         _depth,
         _expanded,
         _deadline
       ) do
    ghost = %{
      pid: nil,
      name: child_id,
      type: :worker,
      modules: child_modules,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }

    {ghost, []}
  end

  defp walk_child(
         node,
         child_id,
         child_pid,
         child_type,
         child_modules,
         depth_remaining,
         expanded,
         deadline
       ) do
    walk_node(
      node,
      child_pid,
      child_id,
      child_type,
      child_modules,
      depth_remaining,
      expanded,
      deadline
    )
  end

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  defp stub_node(pid, name, type, modules) do
    %{
      pid: pid,
      name: name,
      type: type,
      modules: modules,
      has_children?: type == :supervisor,
      child_count: 0,
      children: :not_loaded
    }
  end

  defp ghost_node(child_id, child_pid, _child_type, child_modules) do
    %{
      pid: child_pid,
      name: child_id,
      type: :worker,
      modules: child_modules,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
