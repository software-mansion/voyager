# Seeds a node with ETS tables covering every case the Voyager ETS UI handles.
#
# Run:
#   dev/mock_nodes/ets.sh
#
# Then in Voyager connect to ets@127.0.0.1 with cookie "demo".

defmodule Demo do
  # Protected and private tables only accept writes from their owner, so every call runs there.
  def run(fun) do
    Agent.get(__MODULE__, fn _ ->
      try do
        {:ok, fun.()}
      rescue
        e -> {:error, e}
      end
    end)
  end

  def new(name, opts \\ [:set, :named_table, :public]), do: run(fn -> :ets.new(name, opts) end)
  def put(tab, records), do: run(fn -> :ets.insert(tab, records) end)
  def delete(tab, key), do: run(fn -> :ets.delete(tab, key) end)
  def clear(tab), do: run(fn -> :ets.delete_all_objects(tab) end)
  def drop(tab), do: run(fn -> :ets.delete(tab) end)

  def give_away(tab), do: run(fn -> :ets.give_away(tab, sleeper(), nil) end)
  def heir(tab), do: run(fn -> :ets.setopts(tab, {:heir, sleeper(), nil}) end)
  def heir(tab, :none), do: run(fn -> :ets.setopts(tab, {:heir, :none}) end)

  # Type, protection, keypos, named_table, compressed and concurrency are fixed at :ets.new.
  def recreate(tab, changes) do
    run(fn ->
      info = Keyword.merge(:ets.info(tab), changes)
      rows = :ets.tab2list(tab)
      :ets.delete(tab)
      new_tab = :ets.new(info[:name], opts(info))
      :ets.insert(new_tab, rows)
      new_tab
    end)
  end

  defp opts(info) do
    flags = for flag <- [:named_table, :compressed], info[flag], do: flag
    heir = if is_pid(info[:heir]), do: [{:heir, info[:heir], nil}], else: []

    [
      info[:type],
      info[:protection],
      keypos: info[:keypos],
      read_concurrency: info[:read_concurrency],
      write_concurrency: info[:write_concurrency],
      decentralized_counters: info[:decentralized_counters]
    ] ++ flags ++ heir
  end

  defp sleeper, do: spawn(fn -> Process.sleep(:infinity) end)
end

{:ok, _} = Agent.start(fn -> nil end, name: Demo)

{:ok, _} =
  Demo.run(fn ->
    # --- Truncated-binary-key repro -------------------------------------------
    # In :truncated_key_bug, one key is an 8000-byte binary.
    # 1. Open the table, set "Budget per record" to 100, Fetch records.
    # 2. The long key renders as a silent ~99-byte prefix; Lookup stays enabled.
    # 3. Click Lookup -> "No record with this key. It may have been deleted."
    #    ...but the record exists (this script prints proof on request, see below).
    :ets.new(:truncated_key_bug, [:set, :named_table, :public])
    :ets.insert(:truncated_key_bug, {:binary.copy("K", 8000), :value_a})
    :ets.insert(:truncated_key_bug, {"short-key", :value_b})

    # --- General zoo -----------------------------------------------------------
    :ets.new(:kv_set, [:set, :named_table, :public])

    for i <- 1..137 do
      :ets.insert(:kv_set, {i, %{name: "item_#{i}", tags: [:a, :b], score: i * 1.5}})
    end

    :ets.new(:users_ordered, [:ordered_set, :named_table, :public])

    for i <- 1..23 do
      :ets.insert(
        :users_ordered,
        {"user-#{String.pad_leading(to_string(i), 3, "0")}", i, :active}
      )
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

    :ets.new(:huge_records, [:set, :named_table, :public])
    :ets.insert(:huge_records, {:big_binary, :crypto.strong_rand_bytes(5_000_000)})

    deep =
      Enum.reduce(1..30, :leaf, fn i, acc ->
        %{level: i, child: acc, pad: List.duplicate(i, 50)}
      end)

    :ets.insert(:huge_records, {:deep_term, deep})
    :ets.insert(:huge_records, {:long_list, Enum.to_list(1..100_000)})
    :ets.insert(:huge_records, {:small, :ok})

    :ets.new(:charlist_keys, [:set, :named_table, :public])
    :ets.insert(:charlist_keys, {~c"compiler", ~c"/lib/compiler", []})

    :ets.new(:tuple_keys, [:set, :named_table, :public])
    :ets.insert(:tuple_keys, {{:user, 1}, "alice"})
    :ets.insert(:tuple_keys, {{:user, 2}, "bob"})

    :ets.new(:binary_keys, [:set, :named_table, :public])
    :ets.insert(:binary_keys, {"session-abc", %{ttl: 300}})

    :ets.new(:truncated_struct_key, [:set, :named_table, :public])

    :ets.insert(
      :truncated_struct_key,
      {%Version{major: 1, minor: 0, patch: 0, pre: [:binary.copy("P", 500)]}, :value_a}
    )

    :ets.insert(:truncated_struct_key, {%Version{major: 2, minor: 0, patch: 0}, :value_b})

    :ets.new(:empty_set, [:set, :named_table, :public])
  end)

IO.puts("""
node ready: #{node()}  (cookie: demo)

repro check from another shell (proves the record the UI calls deleted exists):

  elixir --name probe@127.0.0.1 --cookie demo -e '
    n = :"#{node()}"; true = Node.connect(n)
    key = :binary.copy("K", 8000)
    IO.inspect(full_key: :erpc.call(n, :ets, :lookup, [:truncated_key_bug, key]) != [],
               prefix_99: :erpc.call(n, :ets, :lookup, [:truncated_key_bug, :binary.part(key, 0, 99)]))'
""")
