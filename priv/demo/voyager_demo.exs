defmodule VoyagerDemo.Worker do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name) do
    :timer.send_interval(1_000, :tick)
    {:ok, %{name: name, ticks: 0}}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, %{state | ticks: state.ticks + 1}}
end

defmodule VoyagerDemo.Tables do
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    seed()
    {:ok, nil}
  end

  defp seed do
    :ets.new(:kv_set, [:set, :named_table, :public])

    for i <- 1..137 do
      :ets.insert(:kv_set, {i, %{name: "item_#{i}", tags: [:a, :b], score: i * 1.5}})
    end

    :ets.new(:users_ordered, [:ordered_set, :named_table, :public])

    for i <- 1..23 do
      :ets.insert(:users_ordered, {"user-#{String.pad_leading(to_string(i), 3, "0")}", i, :active})
    end

    :ets.new(:by_second_key, [:set, :named_table, :public, {:keypos, 2}])
    :ets.insert(:by_second_key, {%{payload: 1}, :alpha, "extra"})
    :ets.insert(:by_second_key, {%{payload: 2}, :beta, "extra2"})

    :ets.new(:bag_events, [:bag, :named_table, :public])
    :ets.insert(:bag_events, for(i <- 1..60, do: {:login, "user-#{i}", i}))
    :ets.insert(:bag_events, {:logout, "alice", 61})

    :ets.new(:dup_bag, [:duplicate_bag, :named_table, :public])
    :ets.insert(:dup_bag, List.duplicate({:x, 1}, 25))
    :ets.insert(:dup_bag, {:y, 2})

    :ets.new(:private_tab, [:set, :named_table, :private])
    :ets.insert(:private_tab, {:secret, 42})

    unnamed = :ets.new(:anon_data, [:set, :public])
    for i <- 1..12, do: :ets.insert(unnamed, {i, {:anon, i}})

    :ets.new(:tuple_keys, [:set, :named_table, :public])
    :ets.insert(:tuple_keys, {{:user, 1}, "alice"})
    :ets.insert(:tuple_keys, {{:user, 2}, "bob"})

    :ets.new(:empty_set, [:set, :named_table, :public])

    :ets.new(:all_elixir_types, [:ordered_set, :named_table, :public])

    :ets.insert(:all_elixir_types, [
      {:atom, :ok},
      {:atom_quoted, :"hello world"},
      {:integer_big, 2 ** 100},
      {:float, 3.14},
      {:binary, "hello"},
      {:binary_unicode, "zażółć 🚀"},
      {:binary_bytes, <<0, 1, 2, 255>>},
      {:bitstring, <<1::3>>},
      {:charlist, ~c"hello"},
      {:list_improper, [1, 2 | :tail]},
      {:keyword, [name: "voyager", port: 4000, opts: [timeout: 5_000]]},
      {:tuple, {:ok, "value"}},
      {:map, %{name: "voyager", tags: [:a, :b]}},
      {:struct_uri, URI.parse("https://user@example.com:8080/path?q=1#top")},
      {:struct_datetime, ~U[2026-10-16 12:34:56Z]},
      {:struct_range, 1..10},
      {:struct_mapset, MapSet.new([1, :a, "b"])},
      {:struct_regex, ~r/^voy(ager)?$/iu},
      {:pid, self()},
      {:reference, make_ref()},
      {:fun_external, &Enum.map/2},
      {:fun_anonymous, fn x -> x * 2 end}
    ])
  end
end

defmodule VoyagerDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    workers =
      for name <- [:demo_worker_1, :demo_worker_2, :demo_worker_3] do
        Supervisor.child_spec({VoyagerDemo.Worker, name}, id: name)
      end

    Supervisor.start_link([VoyagerDemo.Tables | workers],
      strategy: :one_for_one,
      name: VoyagerDemo.Supervisor
    )
  end
end

defmodule VoyagerDemo do
  def start do
    spec =
      {:application, :voyager_demo,
       [
         description: ~c"Voyager demo node",
         vsn: ~c"0.1.0",
         modules: [VoyagerDemo.Application, VoyagerDemo.Tables, VoyagerDemo.Worker],
         registered: [VoyagerDemo.Supervisor, VoyagerDemo.Tables],
         applications: [:kernel, :stdlib, :elixir],
         mod: {VoyagerDemo.Application, []}
       ]}

    :ok = :application.load(spec)
    {:ok, _started} = :application.ensure_all_started(:voyager_demo)
    :ok
  end
end
