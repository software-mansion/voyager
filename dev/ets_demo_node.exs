# Seeds a node with ETS tables covering every case the Voyager ETS UI handles.
#
# Run:
#   elixir --name demo@127.0.0.1 --cookie demo ets_demo_node.exs
#
# Then in Voyager connect to demo@127.0.0.1 with cookie "demo".

# --- Truncated-binary-key repro -------------------------------------------
# In :truncated_key_bug, one key is an 8000-byte binary.
# 1. Open the table, set "Budget per record" to 100, Fetch records.
# 2. The long key renders as a silent ~99-byte prefix; Lookup stays enabled.
# 3. Click Lookup -> "No record with this key. It may have been deleted."
#    ...but the record exists (this script prints proof on request, see below).
:ets.new(:truncated_key_bug, [:set, :named_table, :public])
:ets.insert(:truncated_key_bug, {:binary.copy("K", 8000), :value_a})
:ets.insert(:truncated_key_bug, {"short-key", :value_b})

# With the default budget (5000) the same key is cut at the agent's hard
# 4096-byte binary cap instead - that case the UI does flag (warning icon,
# no Lookup).

# --- General zoo -----------------------------------------------------------
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
:ets.insert(:bag_events, {:login, "alice", 1})
:ets.insert(:bag_events, {:login, "bob", 2})
:ets.insert(:bag_events, {:logout, "alice", 3})

:ets.new(:dup_bag, [:duplicate_bag, :named_table, :public])
:ets.insert(:dup_bag, {:x, 1})
:ets.insert(:dup_bag, {:x, 1})

:ets.new(:private_tab, [:set, :named_table, :private])
:ets.insert(:private_tab, {:secret, 42})

unnamed = :ets.new(:anon_data, [:set, :public])
for i <- 1..12, do: :ets.insert(unnamed, {i, {:anon, i}})

:ets.new(:huge_records, [:set, :named_table, :public])
:ets.insert(:huge_records, {:big_binary, :crypto.strong_rand_bytes(5_000_000)})
deep = Enum.reduce(1..30, :leaf, fn i, acc -> %{level: i, child: acc, pad: List.duplicate(i, 50)} end)
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

:ets.new(:empty_set, [:set, :named_table, :public])

IO.puts("""
node ready: #{node()}  (cookie: demo)

repro check from another shell (proves the record the UI calls deleted exists):

  elixir --name probe@127.0.0.1 --cookie demo -e '
    n = :"demo@127.0.0.1"; true = Node.connect(n)
    key = :binary.copy("K", 8000)
    IO.inspect(full_key: :erpc.call(n, :ets, :lookup, [:truncated_key_bug, key]) != [],
               prefix_99: :erpc.call(n, :ets, :lookup, [:truncated_key_bug, :binary.part(key, 0, 99)]))'
""")

Process.sleep(:infinity)
