# Seeds a node with a supervised app whose workers cover every link, monitor and
# monitored-by kind the supervision tree and its details panel render.
#
# Run:
#   dev/mock_nodes/relations.sh
#
# Then in Voyager connect to relations@127.0.0.1 with cookie "demo" and open the
# relations_demo app in the supervision tree.

defmodule RelationsDemo do
  def idle, do: Process.sleep(:infinity)
  def cat_port, do: Port.open({:spawn, "cat"}, [:binary])
end

defmodule RelationsDemo.Idle do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(nil), do: {:ok, nil}
end

defmodule RelationsDemo.Peer do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)

  @impl true
  def init(nil), do: {:ok, RelationsDemo.cat_port()}

  @impl true
  def handle_call(:port, _from, port), do: {:reply, port, port}
end

defmodule RelationsDemo.Hub do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    peer = Process.whereis(RelationsDemo.Peer)
    Process.link(peer)
    Process.monitor(peer)
    Process.monitor({RelationsDemo.Peer, node()})
    Port.monitor(RelationsDemo.Peer.port())
    :erlang.monitor(:time_offset, :clock_service)

    hub = self()
    off_tree_linked = spawn_link(&RelationsDemo.idle/0)
    Process.monitor(spawn(&RelationsDemo.idle/0))
    spawn(fn -> Process.monitor(hub) && RelationsDemo.idle() end)

    # A :socket is a NIF resource that monitors its owner, so it shows up as a reference.
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)

    {:ok, %{port: RelationsDemo.cat_port(), socket: socket, linked: off_tree_linked}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule RelationsDemo.Watcher do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, Process.monitor(Process.whereis(RelationsDemo.Hub))}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule RelationsDemo.Crowd do
  use GenServer

  @per_relation 15

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    crowd = self()

    for _ <- 1..@per_relation do
      spawn_link(&RelationsDemo.idle/0)
      Process.monitor(spawn(&RelationsDemo.idle/0))
      spawn(fn -> Process.monitor(crowd) && RelationsDemo.idle() end)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule RelationsDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    inner = %{
      id: RelationsDemo.Inner,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             Supervisor.child_spec({RelationsDemo.Idle, :idle_a}, id: :idle_a),
             Supervisor.child_spec({RelationsDemo.Idle, :idle_b}, id: :idle_b)
           ],
           [strategy: :one_for_one, name: RelationsDemo.Inner]
         ]}
    }

    children = [
      RelationsDemo.Peer,
      RelationsDemo.Hub,
      RelationsDemo.Watcher,
      RelationsDemo.Crowd,
      inner
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RelationsDemo.Supervisor)
  end
end

:ok =
  :application.load(
    {:application, :relations_demo,
     description: ~c"Relations demo",
     vsn: ~c"0.1.0",
     modules: [],
     registered: [],
     applications: [:kernel, :stdlib, :elixir],
     mod: {RelationsDemo.Application, []}}
  )

{:ok, _} = Application.ensure_all_started(:relations_demo)
