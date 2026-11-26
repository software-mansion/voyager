# Seeds a node with ETS tables covering every case the Voyager ETS UI handles.
#
# Run:
#   dev/mock_nodes/ex_ets.sh
#
# Then in Voyager connect to "ex_ets@127.0.0.1" with cookie "demo".

Code.require_file("../../priv/demo/ets_demo.exs", __DIR__)
{:ok, _} = Agent.start(&EtsDemo.seed/0, name: EtsDemo)

{:ok, _} =
  EtsDemo.run(fn ->
    # --- Truncated-binary-key repro -------------------------------------------
    # In :truncated_key_bug, one key is an 8000-byte binary.
    # 1. Open the table, set "Budget per record" to 100, Fetch records.
    # 2. The long key renders as a silent ~99-byte prefix; Lookup stays enabled.
    # 3. Click Lookup -> "No record with this key. It may have been deleted."
    #    ...but the record exists (this script prints proof on request, see below).
    :ets.new(:truncated_key_bug, [:set, :named_table, :public])
    :ets.insert(:truncated_key_bug, {:binary.copy("K", 8000), :value_a})
    :ets.insert(:truncated_key_bug, {"short-key", :value_b})
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
