defmodule Voyager.Services.SupervisionTree.Fetch do
  @moduledoc """
  Wraps a `Voyager.Services.SupervisionTree.Walker.walk/4` call as a cancellable, monitored
  async task that a LiveView can launch and abort.

  ## Usage

      request = %{
        node: :"target@localhost",
        apps: [:my_app],
        depth: 3,
        expanded: MapSet.new()
      }

      task = Fetch.start(request)
      # Later, to cancel:
      Fetch.cancel(task)

  ## Message protocol

  When the walk completes successfully, the owning process receives:

      {ref, {status, result, errors}}

  where `ref` is `task.ref`, `status` is `:ok` or `:partial`, `result` is the
  walker result map `%{nodes: node_map, edges: edge_map}`, and `errors` is a
  list of error tuples.

  If the underlying task crashes, the owning process receives a DOWN message:

      {:DOWN, ref, :process, _pid, reason}

  Because `Task.Supervisor.async_nolink/2` is used, task crashes **never**
  propagate to the caller — the LiveView process is safe regardless of what
  happens during the walk.
  """

  alias Voyager.Services.SupervisionTree.Walker

  @type request :: %{
          node: node(),
          apps: [atom()],
          depth: non_neg_integer(),
          expanded: MapSet.t(pid())
        }

  @doc """
  Starts an async walk for `request`. Returns a task that must be kept
  by the caller and passed to `cancel/1` if early termination is needed.

  The result arrives as `{task.ref, {status, result, errors}}`.
  Crashes arrive as `{:DOWN, task.ref, :process, _pid, reason}`.
  """
  @spec start(request()) :: Task.t()
  def start(request) do
    Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
      Walker.walk(request.node, request.apps, request.depth, request.expanded)
    end)
  end

  @doc """
  Cancels an in-flight fetch. Demonitors the task reference (flushing any
  queued DOWN messages) and terminates the child process. Safe to call even if
  the task has already finished — the `{:error, :not_found}` from
  `Task.Supervisor.terminate_child/2` is silently ignored.

  Always returns `:ok`.
  """
  @spec cancel(Task.t()) :: :ok
  def cancel(task) do
    Process.demonitor(task.ref, [:flush])

    case Task.Supervisor.terminate_child(Voyager.TaskSupervisor, task.pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
