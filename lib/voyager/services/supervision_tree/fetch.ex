defmodule Voyager.Services.SupervisionTree.Fetch do
  @moduledoc """
  Coordinates an async fetch of a (currently mocked) supervision tree.

  Wraps `Task.Supervisor.async_nolink/2` with a `start`/`cancel` lifecycle so
  the LiveView can swap in-flight requests when the user changes scope.
  """

  @type request :: %{
          node: node(),
          apps: [atom()],
          depth: non_neg_integer(),
          expanded: MapSet.t(pid())
        }

  @type state :: %{ref: Task.ref(), task: Task.t(), request: request()}

  @doc """
  Starts an async fetch that delivers a mock supervision tree.

  The result arrives as `{state.ref, {status, tree, errors}}`.
  """
  @spec start(request()) :: state()
  def start(request) do
    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        Process.sleep(200)
        build_mock_result(request)
      end)

    %{ref: task.ref, task: task, request: request}
  end

  @doc """
  Cancels an in-flight fetch. Always returns `:ok`.
  """
  @spec cancel(state()) :: :ok
  def cancel(%{task: task}) do
    Process.demonitor(task.ref, [:flush])

    case Task.Supervisor.terminate_child(Voyager.TaskSupervisor, task.pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp build_mock_result(request) do
    tree =
      Enum.reduce(request.apps, %{}, fn app, acc ->
        Map.put(acc, app, mock_app_node(app, request.depth, request.expanded))
      end)

    {:ok, tree, []}
  end

  defp mock_app_node(app, depth, expanded) do
    {root_id, _, _, _} = app_tree_spec(app)
    root_pid = stable_pid(app, root_id)

    root_sup = build_from_spec(app, app_tree_spec(app), depth - 1, expanded)

    %{
      pid: root_pid,
      name: app,
      type: :app,
      modules: [],
      info: nil,
      has_children?: true,
      child_count: 1,
      children: [root_sup]
    }
  end

  # ---------------------------------------------------------------------------
  # Private — spec-driven recursive tree builder
  #
  # Spec format: {id, name, type, children_spec | :leaf | :ghost}
  #   - :leaf  → worker with a real PID
  #   - :ghost → worker with pid: nil (simulates a restarting child)
  #   - [...] → supervisor whose children follow depth/expanded rules
  # ---------------------------------------------------------------------------

  defp build_from_spec(app, {id, name, :supervisor, children_specs}, depth, expanded) do
    pid = stable_pid(app, id)

    if depth > 0 or MapSet.member?(expanded, pid) do
      children =
        Enum.map(children_specs, &build_from_spec(app, &1, max(depth - 1, 0), expanded))

      %{
        pid: pid,
        name: name,
        type: :supervisor,
        modules: [],
        info: nil,
        has_children?: children != [],
        child_count: length(children),
        children: children
      }
    else
      %{
        pid: pid,
        name: name,
        type: :supervisor,
        modules: [],
        info: nil,
        has_children?: true,
        child_count: length(children_specs),
        children: :not_loaded
      }
    end
  end

  defp build_from_spec(app, {id, name, :worker, :leaf}, _depth, _expanded) do
    %{
      pid: stable_pid(app, id),
      name: name,
      type: :worker,
      modules: [],
      info: nil,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }
  end

  defp build_from_spec(_app, {_id, name, :worker, :ghost}, _depth, _expanded) do
    %{
      pid: nil,
      name: name,
      type: :worker,
      modules: [],
      info: nil,
      has_children?: false,
      child_count: 0,
      children: :not_loaded
    }
  end

  # ---------------------------------------------------------------------------
  # Private — demo tree spec
  #
  # At default depth=3 the tree renders as follows:
  #
  #   <app> (app wrapper)
  #   └── <app>_supervisor (supervisor)
  #       ├── <app>_auth_supervisor (supervisor)
  #       │   ├── <app>_token_server    (worker)
  #       │   └── <app>_session_server  (worker)
  #       ├── <app>_web_endpoint       (worker)
  #       ├── <app>_cache_supervisor   (supervisor)
  #       │   ├── <app>_cache_server_sup (supervisor - STUB at depth=3)
  #       │   └── <app>_cache_eviction   (worker)
  #       └── <app>_worker_supervisor  (supervisor)
  #           ├── <app>_worker_1       (worker)
  #           ├── <app>_worker_2       (worker)
  #           ├── <app>_worker_3       (worker)
  #           ├── <app>_worker_4       (worker)
  #           ├── <app>_worker_5       (worker)
  #           ├── <app>_worker_6       (worker)
  #           └── restarting_worker    (ghost — pid: nil)
  #
  # The cache server supervisor becomes stub (children: :not_loaded) at the
  # default depth because it sit 3 levels below the app root. Expanding it
  # reveals its children, exercising the expand/collapse code path.
  # ---------------------------------------------------------------------------

  defp app_tree_spec(app) do
    a = app

    {:"#{a}_supervisor", :"#{a}_supervisor", :supervisor,
     [
       {:"#{a}_auth_supervisor", :"#{a}_auth_supervisor", :supervisor,
        [
          {:"#{a}_token_server", :"#{a}_token_server", :worker, :leaf},
          {:"#{a}_session_server", :"#{a}_session_server", :worker, :leaf}
        ]},
       {:"#{a}_web_endpoint", :"#{a}_web_endpoint", :worker, :leaf},
       {:"#{a}_cache_supervisor", :"#{a}_cache_supervisor", :supervisor,
        [
          {:"#{a}_cache_server_sup", :"#{a}_cache_server_sup", :supervisor,
           [
             {:"#{a}_cache_shard_1", :"#{a}_cache_shard_1", :supervisor,
              [
                {:"#{a}_shard_1_w1", :"#{a}_shard_1_w1", :worker, :leaf},
                {:"#{a}_shard_1_w2", :"#{a}_shard_1_w2", :worker, :leaf}
              ]},
             {:"#{a}_cache_shard_2", :"#{a}_cache_shard_2", :supervisor,
              [
                {:"#{a}_shard_2_w1", :"#{a}_shard_2_w1", :worker, :leaf},
                {:"#{a}_shard_2_w2", :"#{a}_shard_2_w2", :worker, :leaf}
              ]}
           ]},
          {:"#{a}_cache_eviction", :"#{a}_cache_eviction", :worker, :leaf}
        ]},
       {:"#{a}_worker_supervisor", :"#{a}_worker_supervisor", :supervisor,
        [
          {:"#{a}_worker_1", :"#{a}_worker_1", :worker, :leaf},
          {:"#{a}_worker_2", :"#{a}_worker_2", :worker, :leaf},
          {:"#{a}_worker_3", :"#{a}_worker_3", :worker, :leaf},
          {:"#{a}_worker_4", :"#{a}_worker_4", :worker, :leaf},
          {:"#{a}_worker_5", :"#{a}_worker_5", :worker, :leaf},
          {:"#{a}_worker_6", :"#{a}_worker_6", :worker, :leaf},
          {:restarting_worker, :restarting_worker, :worker, :ghost}
        ]}
     ]}
  end

  # ---------------------------------------------------------------------------
  # Private — stable PIDs
  #
  # PIDs must survive across fetches so the LiveView's `expanded` MapSet (which
  # holds PIDs from previous results) can match nodes in subsequent fetches.
  # :persistent_term gives us a lightweight per-node cache that lives for the
  # duration of the VM. One sleeping process is spawned per unique {app, id}.
  # ---------------------------------------------------------------------------

  defp stable_pid(app, id) do
    key = {__MODULE__, app, id}

    case :persistent_term.get(key, nil) do
      nil ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        :persistent_term.put(key, pid)
        pid

      pid ->
        pid
    end
  end
end
