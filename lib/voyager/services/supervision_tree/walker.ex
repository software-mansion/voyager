defmodule Voyager.Services.SupervisionTree.Walker do
  @moduledoc """
  Produces a lazy, bounded supervision tree for a set of OTP applications on a
  remote node, augmented with the link / monitor / monitored-by relationships
  of every discovered process.

  The tree walk is time-bounded by `@walk_deadline_ms`.  Nodes beyond the
  requested depth or outside the `expanded_pids` set are returned as stubs
  (`children: :not_loaded`).  One batched `process_info` RPC call is issued at
  the end to hydrate all nodes with runtime metrics (including their
  `:links`, `:monitors`, and `:monitored_by`).

  After hydration the walker derives a **relationship edge set** from each
  process's links/monitors:

    * supervisors contribute only their *linked ports*;
    * workers contribute their `:links` (minus the supervision parent),
      `:monitored_by`, and `:monitors`;
    * the application root supervisor's parent is recovered from its
      `$ancestors` (the application master), and the `:app` node is keyed by
      that ancestor.

  Relationship targets that are not part of the supervision tree (external
  processes, ports, references) are returned as standalone leaf nodes in
  `rel_nodes` so the client can render them. The walk goes **one hop** —
  relationship targets are never expanded further.

  ## Return value

      {:ok | :partial, walk_result(), [error()]}

  where

      walk_result :: %{
        tree: %{app_atom => tree_node()},
        relations: [relation()],
        rel_nodes: [rel_node()]
      }

  ## Tree node shape

      %{
        pid: pid() | nil,
        name: atom() | String.t(),
        type: :app | :supervisor | :worker | :port | :reference,
        modules: [module()] | :dynamic,
        info: map() | :dead | nil,
        has_children?: boolean(),
        child_count: non_neg_integer(),
        children: [tree_node()] | :not_loaded
      }

  `child_count` is the *direct* child count on the remote, sourced from
  `:supervisor.count_children/1` for stub supervisors and `length(children)`
  for fully-walked ones.  Workers and ghost nodes always carry `0`.

  ## Relationship shapes

      relation :: %{
        from: pid(),
        to: pid() | port() | reference(),
        kind: :link | :monitor | :monitored_by
      }

      rel_node :: %{
        id: pid() | port() | reference(),
        name: term(),
        type: :worker | :port | :reference,
        info: map() | :dead | nil
      }

  ## Error shape

      {stage :: atom(), identifier :: term(), reason :: term()}

  Example errors:

      {:root_supervisor, :voyager_fixture, :not_running}
      {:which_children, pid, :timeout}
      {:deadline, pid, :exceeded}
      {:process_info, :batch, reason}
      {:relationships, pid, :truncated}
  """

  alias Voyager.Services.SupervisionTree.Remote

  @walk_deadline_ms 3_000
  @max_concurrency 4
  @max_rel_per_node 50

  @type tree_node :: %{
          pid: pid() | nil,
          name: atom() | String.t(),
          type: :app | :supervisor | :worker | :port | :reference,
          modules: [module()] | :dynamic,
          info: map() | :dead | nil,
          has_children?: boolean(),
          child_count: non_neg_integer(),
          children: [tree_node()] | :not_loaded
        }

  @type relation :: %{
          from: pid(),
          to: pid() | port() | reference(),
          kind: :link | :monitor | :monitored_by
        }

  @type rel_node :: %{
          id: pid() | port() | reference(),
          name: term(),
          type: :worker | :port | :reference,
          info: map() | :dead | nil
        }

  @type walk_result :: %{
          tree: %{atom() => tree_node()},
          relations: [relation()],
          rel_nodes: [rel_node()]
        }

  @type error :: {atom(), term(), term()}

  @doc """
  Walks the supervision trees for `apps` on `node`.

  `depth` controls how many supervisor levels below each app root are fully
  expanded.  `expanded` is a `MapSet` of PIDs that must be expanded regardless
  of depth — useful for user-triggered lazy loading.

  Returns `{:ok, walk_result, []}` on success, or `{:partial, walk_result,
  errors}` when some parts of the tree could not be retrieved.
  """
  @spec walk(node(), [atom()], non_neg_integer(), MapSet.t(pid())) ::
          {:ok | :partial, walk_result(), [error()]}
  def walk(node, apps, depth, expanded) do
    deadline = now_ms() + @walk_deadline_ms

    {tree_map, all_errors} =
      Enum.reduce(apps, {%{}, []}, fn app, {acc_tree, acc_errors} ->
        case Remote.root_supervisor(node, app) do
          {:error, reason} ->
            error = {:root_supervisor, app, reason}
            {acc_tree, [error | acc_errors]}

          {:ok, root_pid} ->
            app_pid = ancestor_pid(node, root_pid)

            {root_node, node_errors} =
              walk_node(node, root_pid, app, :supervisor, [], depth - 1, expanded, deadline)

            app_node = %{
              pid: app_pid,
              name: app,
              type: :app,
              modules: [],
              info: nil,
              has_children?: true,
              child_count: 1,
              children: [root_node]
            }

            {Map.put(acc_tree, app, app_node), node_errors ++ acc_errors}
        end
      end)

    {tree_map, all_errors} = hydrate_info(node, tree_map, all_errors)

    {relations, rel_nodes, rel_errors} = build_relations(node, tree_map)

    result = %{tree: tree_map, relations: relations, rel_nodes: rel_nodes}

    errors = Enum.reverse(all_errors) ++ rel_errors

    if errors == [] do
      {:ok, result, []}
    else
      {:partial, result, errors}
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
      info: nil,
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
      info: nil,
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
          info: nil,
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
          info: nil,
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
      info: nil,
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
      info: nil,
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
      info: nil,
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
      info: nil,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }
  end

  # Recovers the real parent of an app's root supervisor from its `$ancestors`
  # (typically the application master). Falls back to the root pid itself when
  # no ancestor is recorded.
  defp ancestor_pid(node, root_pid) do
    case Remote.ancestors(node, root_pid) do
      {:ok, [ancestor | _]} when is_pid(ancestor) -> ancestor
      _ -> root_pid
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ---------------------------------------------------------------------------
  # Private — info hydration
  # ---------------------------------------------------------------------------

  defp hydrate_info(node, tree_map, errors) do
    all_pids = collect_pids(tree_map)

    case Remote.process_info_batch(node, all_pids) do
      {:error, reason} ->
        error = {:process_info, :batch, reason}
        {tree_map, [error | errors]}

      {:ok, info_map} ->
        hydrated_tree =
          Map.new(tree_map, fn {app, app_node} ->
            {app, merge_info(app_node, info_map)}
          end)

        {hydrated_tree, errors}
    end
  end

  defp collect_pids(tree_map) do
    Enum.flat_map(tree_map, fn {_app, app_node} ->
      collect_node_pids(app_node)
    end)
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp collect_node_pids(%{pid: pid, children: :not_loaded}) do
    [pid]
  end

  defp collect_node_pids(%{pid: pid, children: children}) when is_list(children) do
    child_pids = Enum.flat_map(children, &collect_node_pids/1)
    [pid | child_pids]
  end

  defp merge_info(%{pid: nil} = node, _info_map), do: node

  defp merge_info(%{pid: pid, children: :not_loaded} = node, info_map) do
    %{node | info: Map.get(info_map, pid)}
  end

  defp merge_info(%{pid: pid, children: children} = node, info_map) when is_list(children) do
    hydrated_children = Enum.map(children, &merge_info(&1, info_map))
    %{node | info: Map.get(info_map, pid), children: hydrated_children}
  end

  # ---------------------------------------------------------------------------
  # Private — relationship discovery
  # ---------------------------------------------------------------------------

  defp build_relations(node, tree_map) do
    seen = tree_map |> collect_pids() |> MapSet.new()

    candidates = collect_relation_candidates(tree_map)

    {raw_rels, cap_errors} =
      Enum.reduce(candidates, {[], []}, fn {n, parent}, {rels_acc, errs_acc} ->
        node_rels = node_relations(n, parent)

        if length(node_rels) > @max_rel_per_node do
          kept = Enum.take(node_rels, @max_rel_per_node)
          {kept ++ rels_acc, [{:relationships, n.pid, :truncated} | errs_acc]}
        else
          {node_rels ++ rels_acc, errs_acc}
        end
      end)

    deduped = dedup_relations(raw_rels)

    target_ids = deduped |> Enum.map(fn {_from, to, _kind} -> to end) |> Enum.uniq()
    external = Enum.reject(target_ids, &MapSet.member?(seen, &1))
    external_pids = Enum.filter(external, &is_pid/1)

    {info_map, pinfo_errors} = fetch_external_info(node, external_pids)

    rel_nodes = Enum.map(external, &build_rel_node(&1, info_map))

    relation_maps =
      Enum.map(deduped, fn {from, to, kind} -> %{from: from, to: to, kind: kind} end)

    {relation_maps, rel_nodes, Enum.reverse(cap_errors) ++ pinfo_errors}
  end

  defp fetch_external_info(_node, []), do: {%{}, []}

  defp fetch_external_info(node, external_pids) do
    case Remote.process_info_batch(node, external_pids) do
      {:ok, info_map} -> {info_map, []}
      {:error, reason} -> {%{}, [{:process_info, :relations, reason}]}
    end
  end

  # Flatten the tree into `{node, supervision_parent_pid}` pairs. The synthetic
  # `:app` node is skipped (its children are walked with the app/ancestor pid as
  # their parent), and `:not_loaded` stubs are leaves.
  defp collect_relation_candidates(tree_map) do
    Enum.flat_map(tree_map, fn {_app, app_node} -> walk_rel(app_node, nil) end)
  end

  defp walk_rel(%{type: :app, pid: app_pid, children: children}, _parent)
       when is_list(children) do
    Enum.flat_map(children, &walk_rel(&1, app_pid))
  end

  defp walk_rel(%{children: children} = node, parent) when is_list(children) do
    [{node, parent} | Enum.flat_map(children, &walk_rel(&1, node.pid))]
  end

  defp walk_rel(%{children: :not_loaded} = node, parent) do
    [{node, parent}]
  end

  # Supervisors contribute only their linked ports (their pid links duplicate
  # the supervision spine and are shown as structural edges).
  defp node_relations(%{type: :supervisor, pid: pid, info: info}, _parent) do
    info
    |> links_of()
    |> Enum.filter(&is_port/1)
    |> Enum.map(fn port -> {pid, port, :link} end)
  end

  # Workers contribute their links (minus the supervision parent), the
  # processes/ports monitoring them, and the processes/ports they monitor.
  defp node_relations(%{type: :worker, pid: pid, info: info}, parent) do
    links = links_of(info) -- [parent]
    link_rels = Enum.map(links, fn target -> {pid, target, :link} end)
    mb_rels = Enum.map(monitored_by_of(info), fn target -> {pid, target, :monitored_by} end)
    mon_rels = Enum.map(monitors_of(info), fn target -> {pid, target, :monitor} end)

    link_rels ++ mb_rels ++ mon_rels
  end

  defp node_relations(_node, _parent), do: []

  defp links_of(%{links: links}) when is_list(links), do: links
  defp links_of(_), do: []

  defp monitored_by_of(%{monitored_by: monitored_by}) when is_list(monitored_by), do: monitored_by
  defp monitored_by_of(_), do: []

  defp monitors_of(%{monitors: monitors}) when is_list(monitors),
    do: Enum.flat_map(monitors, &monitor_target/1)

  defp monitors_of(_), do: []

  defp monitor_target({:process, pid}) when is_pid(pid), do: [pid]
  defp monitor_target({:port, port}) when is_port(port), do: [port]
  defp monitor_target(_), do: []

  # Drop duplicate edges. Links are undirected (A↔B reported from both ends),
  # so they are normalised by term order; monitor/monitored_by stay directed.
  defp dedup_relations(rels) do
    {kept, _seen} =
      Enum.reduce(rels, {[], MapSet.new()}, fn rel, {acc, seen} ->
        sig = rel_sig(rel)

        if MapSet.member?(seen, sig) do
          {acc, seen}
        else
          {[rel | acc], MapSet.put(seen, sig)}
        end
      end)

    Enum.reverse(kept)
  end

  defp rel_sig({from, to, :link}) when from <= to, do: {:link, from, to}
  defp rel_sig({from, to, :link}), do: {:link, to, from}
  defp rel_sig({from, to, kind}), do: {kind, from, to}

  defp build_rel_node(pid, info_map) when is_pid(pid) do
    info = Map.get(info_map, pid)
    %{id: pid, name: rel_pid_name(pid, info), type: :worker, info: info}
  end

  defp build_rel_node(port, _info_map) when is_port(port) do
    %{id: port, name: port, type: :port, info: nil}
  end

  defp build_rel_node(ref, _info_map) when is_reference(ref) do
    %{id: ref, name: ref, type: :reference, info: nil}
  end

  defp rel_pid_name(_pid, %{registered_name: name}) when is_atom(name), do: name
  defp rel_pid_name(pid, _info), do: pid
end
