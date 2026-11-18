defmodule SupervisionTreeDemo do
  alias SupervisionTreeDemo.Worker

  def start do
    :ok =
      :application.load(
        {:application, :supervision_tree_demo,
         description: ~c"Supervision tree demo",
         vsn: ~c"0.1.0",
         modules: [],
         registered: [],
         applications: [:kernel, :stdlib, :elixir],
         mod: {SupervisionTreeDemo.Application, []}}
      )

    {:ok, started} = Application.ensure_all_started(:supervision_tree_demo)

    for i <- 1..5 do
      {:ok, _pid} =
        DynamicSupervisor.start_child(SupervisionTreeDemo.Dynamic, {Worker, label: {:dynamic, i}})
    end

    for i <- 1..2 do
      {:ok, _pid} =
        Task.Supervisor.start_child(SupervisionTreeDemo.Tasks, fn ->
          Process.set_label({:task, i})
          Process.sleep(:infinity)
        end)
    end

    :ok = Supervisor.terminate_child(SupervisionTreeDemo.Ghosts, :stopped)
    {:ok, started}
  end
end

defmodule SupervisionTreeDemo.Worker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(ignore: true), do: :ignore

  def init(opts) do
    if label = opts[:label], do: Process.set_label(label)
    for name <- Keyword.get(opts, :links, []), do: Process.link(GenServer.whereis(name))
    for name <- Keyword.get(opts, :monitors, []), do: Process.monitor(name)
    {:ok, nil}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule SupervisionTreeDemo.Application do
  use Application

  alias SupervisionTreeDemo.Worker

  @impl true
  def start(_type, _args) do
    wide = for i <- 1..40, do: worker({:wide, i}, label: {:wide, i})

    children = [
      sup(SupervisionTreeDemo.OneForAll, :one_for_all, named_workers(:one_for_all, 3)),
      sup(SupervisionTreeDemo.RestForOne, :rest_for_one, named_workers(:rest_for_one, 3)),
      deep(4),
      sup(SupervisionTreeDemo.Wide, :one_for_one, wide),
      {DynamicSupervisor, name: SupervisionTreeDemo.Dynamic},
      {Task.Supervisor, name: SupervisionTreeDemo.Tasks},
      {PartitionSupervisor,
       child_spec: Agent.child_spec(fn -> %{} end),
       name: SupervisionTreeDemo.Partitions,
       partitions: 4},
      sup(SupervisionTreeDemo.Names, :one_for_one, [
        {Registry, keys: :unique, name: SupervisionTreeDemo.Registry, partitions: 2},
        worker(:registered, name: SupervisionTreeDemo.Registered),
        worker(:global, name: {:global, SupervisionTreeDemo.Global}),
        worker(:via, name: {:via, Registry, {SupervisionTreeDemo.Registry, :via}}),
        worker(:unnamed, label: :unnamed),
        %{
          id: :gen_event,
          start: {:gen_event, :start_link, [{:local, SupervisionTreeDemo.Events}]},
          modules: :dynamic
        }
      ]),
      sup(SupervisionTreeDemo.Ghosts, :one_for_one, [
        worker(:ignored, ignore: true),
        Supervisor.child_spec({Task, fn -> :ok end}, id: :finished, restart: :transient),
        worker(:stopped, [])
      ]),
      worker(:bridge,
        name: SupervisionTreeDemo.Bridge,
        links: [:rest_for_one_3],
        monitors: [SupervisionTreeDemo.Level1, SupervisionTreeDemo.Partitions]
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupervisionTreeDemo.Supervisor)
  end

  defp named_workers(prefix, count) do
    for i <- 1..count do
      name = :"#{prefix}_#{i}"
      worker(name, name: name)
    end
  end

  defp worker(id, opts), do: Supervisor.child_spec({Worker, opts}, id: id)

  defp sup(name, strategy, children) do
    %{
      id: name,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: strategy, name: name]]}
    }
  end

  defp deep(levels) do
    leaf = worker(:leaf, name: SupervisionTreeDemo.Leaf)

    Enum.reduce(levels..1//-1, leaf, fn level, child ->
      sup(Module.concat(SupervisionTreeDemo, "Level#{level}"), :one_for_one, [child])
    end)
  end
end
