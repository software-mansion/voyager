defmodule Voyager.Services.SupervisionTree.Walker do
  @moduledoc """
  Produces a **flat**, bounded supervision tree for a set of OTP applications on
  a remote node, augmented with the link / monitor / monitored-by relationships
  of every discovered process.

  Unlike a nested tree, the walk aggregates a key-addressable node map directly —
  no separate flattening pass is required afterwards. Each node references its
  parent and children by **string key** (the format the client renderer and the
  `VoyagerWeb.SupervisionTreeLive.Diff` differ both expect), while all display
  *values* (`name`, `info`, relation endpoints) stay as native Erlang terms and
  are serialised by the `Voyager.Helper` `Jason.Encoder` implementations at
  push time.

  The walk is **breadth-first and batched**: each tree level issues at most one
  `:supervisor.which_children/1` batch (for expanded supervisors) and one
  `:supervisor.count_children/1` batch (for stubs) via remote `:lists.map`, and
  process metrics for the whole tree are hydrated with a single
  `:lists.zipwith(&:erlang.process_info/2, …)` call. This keeps `:erpc`
  round-trips to roughly `6 + 2 × depth` regardless of tree size.

  The walk is time-bounded by `@walk_deadline_ms`. Nodes beyond the requested
  depth or outside the `expanded_pids` set are returned as stubs
  (`children_keys: :not_loaded`).

  After hydration the walker derives a **relationship edge set** from each
  process's links/monitors:

    * supervisors contribute only their *linked ports*;
    * workers contribute their `:links` (minus the supervision parent),
      `:monitored_by`, and `:monitors`.

  Relationship targets that are not part of the supervision tree (external
  processes, ports, references) are merged into `nodes` as parentless leaf
  nodes so the client can render them. The walk goes **one hop** — relationship
  targets are never expanded further.

  ## Return value

      {:ok | :partial, walk_result(), [error()]}

  where

      walk_result :: %{
        nodes: %{key => flat_node()},
        edges: %{id => edge()}
      }

  ## Node shape

      %{
        key: String.t(),
        parent_key: String.t() | nil,
        pid: pid() | nil,
        name: atom() | pid() | term(),
        type: :app | :supervisor | :worker | :port | :reference,
        has_children?: boolean(),
        child_count: non_neg_integer(),
        info: map() | :dead | nil,
        children_keys: [String.t()] | :not_loaded
      }

  Node keys:

    * real-pid node → `"<X.Y.Z>"` (matches `:erlang.pid_to_list/1`)
    * `:app` wrapper → `"app:<app_atom>"`
    * port node → `"port:<inspect(port)>"`
    * reference node → `"ref:<inspect(ref)>"`
    * ghost child (`pid: nil`) → `"<parent_key>::ghost::<inspect(child_id)>"`

  `name` is the process's display label: its `:registered_name` when
  registered, otherwise its pid. Ghost children (`pid: nil`) keep their
  supervisor child-spec id, since they have neither a registered name nor a
  live pid.

  `child_count` is the *direct* child count on the remote, sourced from
  `:supervisor.count_children/1` for stub supervisors and `length(children)`
  for fully-walked ones. Workers and ghost nodes always carry `0`.

  ## Edge shape

      edge :: %{
        id: String.t(),
        source: String.t(),
        target: String.t(),
        kind: String.t()
      }

  Edge keys → `"rel:<kind>:<source>-><target>"`.

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
  @max_rel_per_node 50

  @type flat_node :: %{
          key: String.t(),
          parent_key: String.t() | nil,
          pid: pid() | nil,
          name: atom() | pid() | term(),
          type: :app | :supervisor | :worker | :port | :reference,
          has_children?: boolean(),
          child_count: non_neg_integer(),
          info: map() | :dead | nil,
          children_keys: [String.t()] | :not_loaded
        }

  @type edge :: %{id: String.t(), source: String.t(), target: String.t(), kind: String.t()}

  @type walk_result :: %{
          nodes: %{String.t() => flat_node()},
          edges: %{String.t() => edge()}
        }

  @type error :: {atom(), term(), term()}

  # A pending supervisor to resolve in the breadth-first level loop.
  @typep work_item :: %{
           pid: pid(),
           key: String.t(),
           parent_key: String.t(),
           name: term(),
           depth_remaining: integer()
         }

  @doc """
  Walks the supervision trees for `apps` on `node`.

  `depth` controls how many supervisor levels below each app root are fully
  expanded. `expanded` is a `MapSet` of PIDs that must be expanded regardless
  of depth — useful for user-triggered lazy loading.

  Returns `{:ok, walk_result, []}` on success, or `{:partial, walk_result,
  errors}` when some parts of the tree could not be retrieved.
  """
  @spec walk(node(), [atom()], non_neg_integer(), MapSet.t(pid())) ::
          {:ok | :partial, walk_result(), [error()]}
  def walk(node, apps, depth, expanded) do
    deadline = now_ms() + @walk_deadline_ms

    {nodes, worklist, root_errors} = build_roots(node, apps, depth)

    {nodes, walk_errors} = walk_levels(node, nodes, worklist, expanded, deadline, [])

    {nodes, hydrate_errors} = hydrate(node, nodes)

    {nodes, edges, rel_errors} = build_relations(node, nodes)

    result = %{nodes: nodes, edges: edges}

    errors = root_errors ++ walk_errors ++ hydrate_errors ++ rel_errors

    if errors == [] do
      {:ok, result, []}
    else
      {:partial, result, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # application roots
  # ---------------------------------------------------------------------------

  defp build_roots(node, apps, depth) do
    case Remote.app_masters(node, apps) do
      {:error, reason} ->
        {%{}, [], Enum.map(apps, &{:root_supervisor, &1, reason})}

      {:ok, masters} ->
        {running, not_running} =
          apps
          |> Enum.zip(masters)
          |> Enum.split_with(fn {_app, master} -> is_pid(master) end)

        not_running_errors =
          Enum.map(not_running, fn {app, _} -> {:root_supervisor, app, :not_running} end)

        case build_running_roots(node, running, depth) do
          {:ok, nodes, worklist} ->
            {nodes, worklist, not_running_errors}

          {:error, errors} ->
            {%{}, [], not_running_errors ++ errors}
        end
    end
  end

  defp build_running_roots(_node, [], _depth), do: {:ok, %{}, []}

  defp build_running_roots(node, running, depth) do
    master_pids = Enum.map(running, fn {_app, master} -> master end)

    case Remote.app_children(node, master_pids) do
      {:error, reason} ->
        {:error, Enum.map(running, fn {app, _} -> {:root_supervisor, app, reason} end)}

      {:ok, children} ->
        root_pids = Enum.map(children, &normalize_child/1)
        ancestors = root_ancestors(node, root_pids)

        {nodes, worklist} =
          [running, master_pids, root_pids]
          |> Enum.zip()
          |> Enum.reduce({%{}, []}, fn {{app, _}, master_pid, root_pid}, {nds, wl} ->
            seed_app(nds, wl, app, master_pid, root_pid, Map.fetch!(ancestors, root_pid), depth)
          end)

        {:ok, nodes, worklist}
    end
  end

  defp normalize_child({pid, _app_module}) when is_pid(pid), do: pid
  defp normalize_child(pid) when is_pid(pid), do: pid

  # Builds the `application_master -> p -> root_supervisor` chain for one app and
  # seeds the worklist with the root supervisor. `p` is the root supervisor's
  # recorded `$ancestor`; when it coincides with the master or the root itself,
  # the intermediate chain node is omitted.
  defp seed_app(nodes, worklist, app, master_pid, root_pid, p_pid, depth) do
    app_key = "app:#{app}"
    root_key = id_key(root_pid)

    {root_parent_key, nodes} =
      if p_pid == root_pid or p_pid == master_pid do
        {app_key, Map.put(nodes, app_key, app_node(app_key, master_pid, [root_key]))}
      else
        p_key = id_key(p_pid)

        nodes =
          nodes
          |> Map.put(app_key, app_node(app_key, master_pid, [p_key]))
          |> Map.put(p_key, chain_node(p_key, app_key, p_pid, [root_key]))

        {p_key, nodes}
      end

    item = %{
      pid: root_pid,
      key: root_key,
      parent_key: root_parent_key,
      name: root_pid,
      depth_remaining: depth - 2
    }

    {nodes, [item | worklist]}
  end

  # The app wrapper always has exactly one child: the chain node or, when there
  # is no intermediate `p`, the root supervisor.
  defp app_node(app_key, master_pid, [_single] = children_keys) do
    build_node(%{
      key: app_key,
      pid: master_pid,
      name: master_pid,
      type: :app,
      has_children?: true,
      child_count: 1,
      children_keys: children_keys
    })
  end

  # The intermediate process node (the application master's child `p`). It is
  # not a supervisor we walk; its single child is supplied directly. Typed
  # `:supervisor` so its pid-links (to the master and root supervisor) are
  # treated as structural rather than emitted as relationship edges.
  defp chain_node(p_key, app_key, p_pid, [_single] = children_keys) do
    build_node(%{
      key: p_key,
      parent_key: app_key,
      pid: p_pid,
      name: p_pid,
      type: :supervisor,
      has_children?: true,
      child_count: 1,
      children_keys: children_keys
    })
  end

  # One batched `process_info(pid, [:dictionary])` for all root pids, reduced to
  # `%{root_pid => p_pid}`. Failures (or absent `$ancestors`) default `p` to the
  # root pid itself, so no chain node is inserted.
  defp root_ancestors(node, root_pids) do
    info_map =
      case Remote.process_info_many(node, root_pids, [:dictionary]) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    Map.new(root_pids, fn root_pid ->
      {root_pid, ancestor_pid(Map.get(info_map, root_pid), root_pid)}
    end)
  end

  defp ancestor_pid(%{dictionary: dict}, default) when is_list(dict) do
    case Keyword.get(dict, :"$ancestors", []) do
      [ancestor | _] when is_pid(ancestor) -> ancestor
      _ -> default
    end
  end

  defp ancestor_pid(_info, default), do: default

  # ---------------------------------------------------------------------------
  # breadth-first level walk
  # ---------------------------------------------------------------------------

  defp walk_levels(_node, nodes, [], _expanded, _deadline, errors), do: {nodes, errors}

  defp walk_levels(node, nodes, worklist, expanded, deadline, errors) do
    if now_ms() >= deadline do
      {nodes, deadline_errors} = stub_remaining(nodes, worklist)
      {nodes, errors ++ deadline_errors}
    else
      {expand_items, stub_items} =
        Enum.split_with(worklist, fn item ->
          item.depth_remaining > 0 or MapSet.member?(expanded, item.pid)
        end)

      {nodes, stub_errors} = resolve_stubs(node, nodes, stub_items)
      {nodes, next_worklist, expand_errors} = resolve_expansions(node, nodes, expand_items)

      walk_levels(
        node,
        nodes,
        next_worklist,
        expanded,
        deadline,
        errors ++ stub_errors ++ expand_errors
      )
    end
  end

  # Past the deadline: every still-pending supervisor becomes a stub without a
  # further remote call, plus a deadline error.
  defp stub_remaining(nodes, worklist) do
    Enum.reduce(worklist, {nodes, []}, fn item, {nds, errs} ->
      {Map.put(nds, item.key, unresolved_sup_node(item)),
       [{:deadline, item.pid, :exceeded} | errs]}
    end)
  end

  defp resolve_stubs(_node, nodes, []), do: {nodes, []}

  defp resolve_stubs(node, nodes, stub_items) do
    pids = Enum.map(stub_items, & &1.pid)

    stub_items
    |> Enum.zip(count_children_aligned(node, pids))
    |> Enum.reduce({nodes, []}, fn
      {item, {:ok, count}}, {nds, errs} ->
        {Map.put(nds, item.key, stub_node(item, count)), errs}

      {item, {:error, reason}}, {nds, errs} ->
        {Map.put(nds, item.key, stub_node(item, 0)), [{:count_children, item.pid, reason} | errs]}
    end)
    |> then(fn {nds, errs} -> {nds, Enum.reverse(errs)} end)
  end

  defp resolve_expansions(_node, nodes, []), do: {nodes, [], []}

  defp resolve_expansions(node, nodes, expand_items) do
    pids = Enum.map(expand_items, & &1.pid)

    expand_items
    |> Enum.zip(which_children_aligned(node, pids))
    |> Enum.reduce({nodes, [], []}, fn
      {item, {:ok, raw_children}}, {nds, wl, errs} ->
        {nds, wl} = expand_one(item, raw_children, nds, wl)
        {nds, wl, errs}

      {item, {:error, reason}}, {nds, wl, errs} ->
        {Map.put(nds, item.key, unresolved_sup_node(item)), wl,
         [{:which_children, item.pid, reason} | errs]}
    end)
    |> then(fn {nds, wl, errs} -> {nds, wl, Enum.reverse(errs)} end)
  end

  # Resolves one expanded supervisor: inserts its leaf/ghost children, queues
  # its child supervisors for the next level, and inserts the supervisor itself
  # with its `children_keys`.
  defp expand_one(item, raw_children, nodes, worklist) do
    {child_keys_rev, nodes, worklist} =
      Enum.reduce(raw_children, {[], nodes, worklist}, fn raw_child, {keys, nds, wl} ->
        {key, nds, wl} = walk_child(item, raw_child, nds, wl)
        {[key | keys], nds, wl}
      end)

    child_keys = Enum.reverse(child_keys_rev)
    {Map.put(nodes, item.key, sup_node(item, child_keys)), worklist}
  end

  # Ghosts: a child spec with no live pid keeps its child-spec id as its label.
  defp walk_child(item, {child_id, status, _type, _modules}, nodes, worklist)
       when status in [:undefined, :restarting] do
    key = ghost_key(item.key, child_id)
    {key, Map.put(nodes, key, ghost_node(key, item.key, child_id)), worklist}
  end

  # Child supervisors are queued for the next level (their node is inserted when
  # resolved); their key is already known from their pid.
  defp walk_child(item, {child_id, child_pid, :supervisor, _modules}, nodes, worklist)
       when is_pid(child_pid) do
    key = id_key(child_pid)

    next_item = %{
      pid: child_pid,
      key: key,
      parent_key: item.key,
      name: child_id,
      depth_remaining: item.depth_remaining - 1
    }

    {key, nodes, [next_item | worklist]}
  end

  # Workers (and any non-supervisor) are always leaves.
  defp walk_child(item, {child_id, child_pid, _type, _modules}, nodes, worklist)
       when is_pid(child_pid) do
    key = id_key(child_pid)
    {key, Map.put(nodes, key, leaf_node(key, item.key, child_pid, child_id)), worklist}
  end

  # ---------------------------------------------------------------------------
  # batched remote calls with per-pid fallback
  # ---------------------------------------------------------------------------

  defp which_children_aligned(node, pids) do
    batch_with_fallback(
      pids,
      Remote.which_children_many(node, pids),
      &Remote.which_children(node, &1)
    )
  end

  defp count_children_aligned(node, pids) do
    batch_with_fallback(
      pids,
      Remote.count_children_many(node, pids),
      &Remote.count_children(node, &1)
    )
  end

  # Normalises a batched remote result into `[{:ok, value} | {:error, reason}]`
  # aligned with `pids`. If a single element crashed the remote `:lists.map`,
  # falls back to per-pid `fallback_fn` calls to isolate the offending pid.
  defp batch_with_fallback(pids, batch_result, fallback_fn) do
    case batch_result do
      {:ok, values} -> Enum.map(values, &{:ok, &1})
      {:error, {:remote_exception, _}} -> Enum.map(pids, fallback_fn)
      {:error, reason} -> Enum.map(pids, fn _ -> {:error, reason} end)
    end
  end

  # ---------------------------------------------------------------------------
  # node constructors
  # ---------------------------------------------------------------------------

  # All node maps share this skeleton; each constructor overrides only the
  # fields that differ from these defaults.
  @node_defaults %{
    parent_key: nil,
    pid: nil,
    name: nil,
    type: nil,
    has_children?: false,
    child_count: 0,
    info: nil,
    children_keys: :not_loaded
  }

  @spec build_node(map()) :: flat_node()
  defp build_node(attrs), do: Map.merge(@node_defaults, attrs)

  @spec sup_node(work_item(), [String.t()]) :: flat_node()
  defp sup_node(item, child_keys) do
    build_node(%{
      key: item.key,
      parent_key: item.parent_key,
      pid: item.pid,
      name: item.name,
      type: :supervisor,
      has_children?: child_keys != [],
      child_count: length(child_keys),
      children_keys: child_keys
    })
  end

  defp stub_node(item, count) do
    build_node(%{
      key: item.key,
      parent_key: item.parent_key,
      pid: item.pid,
      name: item.name,
      type: :supervisor,
      has_children?: count > 0,
      child_count: count
    })
  end

  # A supervisor whose children could not be listed (remote error) or were not
  # reached before the deadline: keep it expandable so the client still shows a
  # chevron, but with an unknown count. The reason lives in the error tuple.
  defp unresolved_sup_node(item) do
    build_node(%{
      key: item.key,
      parent_key: item.parent_key,
      pid: item.pid,
      name: item.name,
      type: :supervisor,
      has_children?: true
    })
  end

  defp leaf_node(key, parent_key, pid, name) do
    build_node(%{key: key, parent_key: parent_key, pid: pid, name: name, type: :worker})
  end

  defp ghost_node(key, parent_key, child_id) do
    build_node(%{key: key, parent_key: parent_key, name: child_id, type: :worker})
  end

  # ---------------------------------------------------------------------------
  # info hydration
  # ---------------------------------------------------------------------------

  defp hydrate(node, nodes) do
    pids =
      nodes
      |> Map.values()
      |> Enum.map(& &1.pid)
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()

    case Remote.process_info_batch(node, pids) do
      {:error, reason} ->
        {nodes, [{:process_info, :batch, reason}]}

      {:ok, info_map} ->
        {Map.new(nodes, fn {key, n} -> {key, merge_info(n, info_map)} end), []}
    end
  end

  # Ghost nodes (pid: nil) have no live process; they keep their child-spec id.
  defp merge_info(%{pid: nil} = node, _info_map), do: node

  defp merge_info(%{pid: pid} = node, info_map) do
    info = Map.get(info_map, pid)
    %{node | info: info, name: pid_label(pid, info)}
  end

  # A process's display label is its `:registered_name` when registered,
  # otherwise its pid. `:erlang.process_info/2` reports `[]` for an
  # unregistered process, which is not an atom and so falls through to the pid.
  defp pid_label(_pid, %{registered_name: name}) when is_atom(name), do: name
  defp pid_label(pid, _info), do: pid

  # ---------------------------------------------------------------------------
  # relationship discovery
  # ---------------------------------------------------------------------------

  defp build_relations(node, nodes) do
    # One pass collects both the set of in-tree pids (`seen`) and the relation
    # candidates (live supervisors/workers).
    {seen, candidates} =
      Enum.reduce(nodes, {MapSet.new(), []}, fn
        {_key, %{pid: pid} = n}, {seen, candidates} when is_pid(pid) ->
          candidates = if n.type in [:supervisor, :worker], do: [n | candidates], else: candidates
          {MapSet.put(seen, pid), candidates}

        _entry, acc ->
          acc
      end)

    {raw_rels, cap_errors} =
      Enum.reduce(candidates, {[], []}, fn n, {rels_acc, errs_acc} ->
        node_rels = node_relations(n, parent_pid_of(nodes, n))

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

    nodes = Enum.reduce(external, nodes, &put_rel_node(&2, &1, info_map))

    edges = Map.new(deduped, fn {from, to, kind} -> build_edge(from, to, kind) end)

    {nodes, edges, Enum.reverse(cap_errors) ++ pinfo_errors}
  end

  defp parent_pid_of(_nodes, %{parent_key: nil}), do: nil

  defp parent_pid_of(nodes, %{parent_key: parent_key}) do
    case Map.get(nodes, parent_key) do
      %{pid: pid} -> pid
      _ -> nil
    end
  end

  defp fetch_external_info(_node, []), do: {%{}, []}

  defp fetch_external_info(node, external_pids) do
    case Remote.process_info_batch(node, external_pids) do
      {:ok, info_map} -> {info_map, []}
      {:error, reason} -> {%{}, [{:process_info, :relations, reason}]}
    end
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

  defp build_edge(from, to, kind) do
    source = id_key(from)
    target = id_key(to)
    id = "rel:#{kind}:#{source}->#{target}"
    {id, %{id: id, source: source, target: target, kind: to_string(kind)}}
  end

  # Relationship-only nodes are parentless leaves. `put_new` ensures a target
  # that also exists in the supervision tree keeps its richer tree entry.
  defp put_rel_node(nodes, id, info_map) when is_pid(id) do
    info = Map.get(info_map, id)
    Map.put_new(nodes, id_key(id), rel_node(id, id, pid_label(id, info), :worker, info))
  end

  defp put_rel_node(nodes, id, _info_map) when is_port(id) do
    Map.put_new(nodes, id_key(id), rel_node(id, nil, id, :port, nil))
  end

  defp put_rel_node(nodes, id, _info_map) when is_reference(id) do
    Map.put_new(nodes, id_key(id), rel_node(id, nil, id, :reference, nil))
  end

  defp rel_node(id, pid, name, type, info) do
    build_node(%{key: id_key(id), pid: pid, name: name, type: type, info: info})
  end

  # ---------------------------------------------------------------------------
  # keys & helpers
  # ---------------------------------------------------------------------------

  defp id_key(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp id_key(port) when is_port(port), do: "port:#{inspect(port)}"
  defp id_key(ref) when is_reference(ref), do: "ref:#{inspect(ref)}"

  defp ghost_key(parent_key, child_id), do: "#{parent_key}::ghost::#{inspect(child_id)}"

  defp now_ms, do: System.monotonic_time(:millisecond)
end
