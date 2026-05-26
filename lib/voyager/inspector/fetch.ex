defmodule Voyager.Inspector.Fetch do
  @moduledoc """
  Wraps a `Voyager.Inspector.Walker.walk/4` call as a cancellable, monitored
  async task that a LiveView can launch and abort.

  ## Usage

      request = %{
        node: :"target@localhost",
        apps: [:my_app],
        depth: 3,
        expanded: MapSet.new()
      }

      state = Fetch.start(request)
      # Later, to cancel:
      Fetch.cancel(state)

  ## Message protocol

  When the walk completes successfully, the owning process receives:

      {ref, {status, tree, errors}}

  where `ref` is `state.ref`, `status` is `:ok` or `:partial`, `tree` is the
  tree map, and `errors` is a list of error tuples.

  If the underlying task crashes, the owning process receives a DOWN message:

      {:DOWN, ref, :process, _pid, reason}

  Because `Task.Supervisor.async_nolink/2` is used, task crashes **never**
  propagate to the caller — the LiveView process is safe regardless of what
  happens during the walk.
  """

  alias Voyager.Inspector.Walker

  @type request :: %{
          node: node(),
          apps: [atom()],
          depth: non_neg_integer(),
          expanded: MapSet.t(pid())
        }

  @type state :: %{ref: reference(), task: Task.t(), request: request()}

  @doc """
  Starts an async walk for `request`. Returns a state map that must be kept
  by the caller and passed to `cancel/1` if early termination is needed.

  The result arrives as `{state.ref, {status, tree, errors}}`.
  Crashes arrive as `{:DOWN, state.ref, :process, _pid, reason}`.
  """
  @spec start(request()) :: state()
  def start(request) do
    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        Walker.walk(request.node, request.apps, request.depth, request.expanded)
      end)

    %{ref: task.ref, task: task, request: request}
  end

  @doc """
  Cancels an in-flight fetch. Demonitors the task reference (flushing any
  queued DOWN messages) and terminates the child process. Safe to call even if
  the task has already finished — the `{:error, :not_found}` from
  `Task.Supervisor.terminate_child/2` is silently ignored.

  Always returns `:ok`.
  """
  @spec cancel(state()) :: :ok
  def cancel(%{task: task}) do
    Process.demonitor(task.ref, [:flush])

    case Task.Supervisor.terminate_child(Voyager.TaskSupervisor, task.pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
