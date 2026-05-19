defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  @tree_data %{
    name: "my_app@prod-01",
    kind: "node",
    pid: "<node>",
    children: [
      %{
        name: "MyApp.Supervisor",
        kind: "supervisor",
        pid: :c.pid(0, 111_111, 0),
        strategy: ":one_for_one",
        children: [
          %{
            name: "MyApp.Repo",
            kind: "supervisor",
            pid: "<0.235.0>",
            strategy: ":rest_for_one",
            children: [
              %{
                name: "DBConnection.Pool",
                kind: "worker",
                pid: "<0.236.0>",
                memory: "1.2 MB",
                queue: 0,
                children: [
                  %{name: "Postgrex.Conn #1", kind: "worker", pid: "<0.241.0>", memory: "180 KB"},
                  %{name: "Postgrex.Conn #2", kind: "worker", pid: "<0.242.0>", memory: "172 KB"},
                  %{name: "Postgrex.Conn #3", kind: "worker", pid: "<0.243.0>", memory: "168 KB"},
                  %{name: "Postgrex.Conn #4", kind: "worker", pid: "<0.244.0>", memory: "190 KB"}
                ]
              },
              %{name: "Ecto.Migrator", kind: "worker", pid: "<0.237.0>", memory: "84 KB"}
            ]
          },
          %{
            name: "MyAppWeb.Endpoint",
            kind: "supervisor",
            pid: "<0.250.0>",
            strategy: ":one_for_one",
            children: [
              %{
                name: "Phoenix.PubSub",
                kind: "supervisor",
                pid: "<0.251.0>",
                children: [
                  %{
                    name: "Phoenix.PubSub.Local",
                    kind: "worker",
                    pid: "<0.252.0>",
                    memory: "210 KB"
                  },
                  %{
                    name: "Phoenix.PubSub.Adapter",
                    kind: "worker",
                    pid: "<0.253.0>",
                    memory: "98 KB"
                  }
                ]
              },
              %{name: "Cowboy.Listener", kind: "worker", pid: "<0.260.0>", memory: "440 KB"},
              %{
                name: "Phoenix.Channel.Server",
                kind: "supervisor",
                pid: "<0.261.0>",
                children: [
                  %{
                    name: "RoomChannel #4172",
                    kind: "worker",
                    pid: "<0.4172.0>",
                    memory: "62 KB"
                  },
                  %{
                    name: "RoomChannel #4188",
                    kind: "worker",
                    pid: "<0.4188.0>",
                    memory: "58 KB"
                  },
                  %{name: "UserChannel #5021", kind: "worker", pid: "<0.5021.0>", memory: "71 KB"}
                ]
              }
            ]
          },
          %{
            name: "MyApp.Cache",
            kind: "supervisor",
            pid: "<0.270.0>",
            strategy: ":one_for_all",
            children: [
              %{name: "Cachex.Janitor", kind: "worker", pid: "<0.271.0>", memory: "42 KB"},
              %{name: "Cachex.Worker", kind: "worker", pid: "<0.272.0>", memory: "1.8 MB"},
              %{name: "Cachex.Stats", kind: "worker", pid: "<0.273.0>", memory: "38 KB"}
            ]
          },
          %{
            name: "MyApp.Workers.Supervisor",
            kind: "supervisor",
            pid: "<0.280.0>",
            strategy: ":simple_one_for_one",
            children: [
              %{
                name: "EmailWorker #1",
                kind: "worker",
                pid: "<0.281.0>",
                memory: "120 KB",
                queue: 3
              },
              %{
                name: "EmailWorker #2",
                kind: "worker",
                pid: "<0.282.0>",
                memory: "118 KB",
                queue: 1
              },
              %{
                name: "EmailWorker #3",
                kind: "worker",
                pid: "<0.283.0>",
                memory: "124 KB",
                queue: 0
              },
              %{
                name: "ReportWorker #1",
                kind: "worker",
                pid: "<0.284.0>",
                memory: "240 KB",
                queue: 0
              },
              %{
                name: "ReportWorker #2",
                kind: "worker",
                pid: "<0.285.0>",
                memory: "238 KB",
                queue: 2
              }
            ]
          },
          %{
            name: "MyApp.Telemetry",
            kind: "supervisor",
            pid: "<0.290.0>",
            strategy: ":one_for_one",
            children: [
              %{name: "Telemetry.Poller", kind: "worker", pid: "<0.291.0>", memory: "56 KB"},
              %{name: "Telemetry.Metrics", kind: "worker", pid: "<0.292.0>", memory: "82 KB"}
            ]
          }
        ]
      }
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :supervision_tree)
      |> assign(tree_data: %{name: "root", pid: :c.pid(0, 9, 0), children: gen_dummy_tree(15)})
      |> assign(counter: 1)

    # |> assign(tree_data: @tree_data)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <p>Supervision Tree</p>
      <div>{@counter}</div>
      <button class="btn" phx-click="send-data-hook">Send via hook</button>
      <div
        id="node-supervision-tree"
        class="relative flex-1 overflow-hidden"
        phx-hook="SupervisionTree"
      >
        <svg id="tree-svg" class="h-full w-full cursor-grab active:cursor-grabbing"></svg>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("send-data-hook", _, socket) do
    socket =
      socket
      |> push_event("tree-data", %{data: socket.assigns.tree_data})
      |> update(:counter, &(&1 + 1))

    {:noreply, socket}
  end

  def gen_dummy_tree(0) do
    []
  end

  def gen_dummy_tree(depth) do
    # children_num = :rand.uniform(5)

    1..2
    |> Enum.map(
      &%{
        name: "SomeProcessName #{&1}",
        pid: :c.pid(0, &1 + 1000, 0),
        some_data1: :value1,
        some_data2: :value2,
        children: gen_dummy_tree(depth - 1)
      }
    )
  end
end
