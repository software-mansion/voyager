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

    for i <- 1..2 do
      {:ok, _pid} =
        DynamicSupervisor.start_child(SupervisionTreeDemo.Dynamic, {Worker, label: {:dynamic, i}})
    end

    {:ok, _pid} =
      Task.Supervisor.start_child(SupervisionTreeDemo.Tasks, fn ->
        Process.set_label(:task)
        Process.sleep(:infinity)
      end)

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
    {:ok, nil}
  end
end

defmodule SupervisionTreeDemo.Hub do
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    hub = self()
    Process.link(Process.whereis(:rest_for_one_2))
    Process.monitor(Process.whereis(SupervisionTreeDemo.Level1))
    off_tree = spawn_link(fn -> Process.sleep(:infinity) end)
    spawn(fn -> Process.monitor(hub) && Process.sleep(:infinity) end)

    {:ok, port} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    Port.monitor(port)

    # A :socket is a NIF resource that monitors its owner, so it shows up as a reference.
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)

    {:ok, %{off_tree: off_tree, port: port, socket: socket}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule SupervisionTreeDemo.LargeState do
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.put(:request_id, "req-42")
    Process.put(:retries, 3)

    {:ok,
     %{
       users:
         Map.new(1..500, &{&1, %{name: "user_#{&1}", roles: [:reader], active?: rem(&1, 3) != 0}}),
       history: Enum.to_list(1..1_000),
       blob: :binary.copy("voyager ", 20_000),
       owner: self(),
       ref: make_ref(),
       formatter: &String.upcase/1,
       misc: {:ok, ~c"charlist", 3.14}
     }}
  end
end

defmodule SupervisionTreeDemo.StuckMailbox do
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    for i <- 1..200, do: send(self(), {:order, i, %{total: i * 10}})
    {:ok, nil, {:continue, :stall}}
  end

  @impl true
  def handle_continue(:stall, state) do
    Process.sleep(:infinity)
    {:noreply, state}
  end
end

defmodule SupervisionTreeDemo.Application do
  use Application

  alias SupervisionTreeDemo.Worker

  @impl true
  def start(_type, _args) do
    children = [
      sup(SupervisionTreeDemo.OneForAll, :one_for_all, named_workers(:one_for_all)),
      sup(SupervisionTreeDemo.RestForOne, :rest_for_one, named_workers(:rest_for_one)),
      sup(SupervisionTreeDemo.Level1, :one_for_one, [
        sup(SupervisionTreeDemo.Level2, :one_for_one, [
          worker(:leaf, name: SupervisionTreeDemo.Leaf)
        ])
      ]),
      {DynamicSupervisor, name: SupervisionTreeDemo.Dynamic},
      {Task.Supervisor, name: SupervisionTreeDemo.Tasks},
      sup(SupervisionTreeDemo.Names, :one_for_one, [
        {Registry, keys: :unique, name: SupervisionTreeDemo.Registry},
        worker(:via, name: {:via, Registry, {SupervisionTreeDemo.Registry, :via}}),
        worker(:global, name: {:global, SupervisionTreeDemo.Global})
      ]),
      sup(SupervisionTreeDemo.Ghosts, :one_for_one, [
        worker(:ignored, ignore: true),
        worker(:stopped, [])
      ]),
      SupervisionTreeDemo.LargeState,
      SupervisionTreeDemo.StuckMailbox,
      SupervisionTreeDemo.Hub
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupervisionTreeDemo.Supervisor)
  end

  defp named_workers(prefix) do
    for i <- 1..2 do
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
end
