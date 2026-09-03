:code.add_patha(String.to_charlist(__DIR__))
us = fn f -> {t, r} = :timer.tc(f); {t, r} end
mb = fn b -> :erlang.float_to_binary(b/1048576, decimals: 1) <> "MB" end

# --- A: cheap O(1) metrics vs O(n) full copy on a 1,000,000-message mailbox ---
big = spawn(fn -> receive do :stop -> :ok end end)
Enum.each(1..1_000_000, fn i -> send(big, {:msg, i}) end)
:erlang.suspend_process(big); :erlang.resume_process(big)

{t_len, {:message_queue_len, qlen}} = us.(fn -> :erlang.process_info(big, :message_queue_len) end)
{t_mem, {:memory, memq}}            = us.(fn -> :erlang.process_info(big, :memory) end)
{t_msgs, {:messages, msgs}}         = us.(fn -> :erlang.process_info(big, :messages) end)
IO.puts("A) 1,000,000-msg mailbox:")
IO.puts("   message_queue_len -> #{qlen}  in #{t_len} us  (O(1), safe)")
IO.puts("   memory            -> #{mb.(memq)}  in #{t_mem} us  (O(1), includes queue)")
IO.puts("   messages (copy)   -> #{length(msgs)} msgs  in #{div(t_msgs,1000)} ms  (O(n) -- the dangerous read)")

# --- D: is there a capped mailbox read? ---
capped =
  try do :erlang.process_info(big, {:messages, 10}) rescue e -> {:unsupported, e.__struct__} catch k,v -> {:unsupported, {k,v}} end
IO.puts("D) process_info(pid, {messages, 10}) -> #{inspect(capped, limit: 3)}  (no capped read in ERTS)")
send(big, :stop)

# --- B: does a process_info(:memory) gate catch sharing expansion? ---
{:ok, ag} = Agent.start(fn -> x = Enum.to_list(1..65536); List.duplicate(x, 1000) end, [])
_ = :sys.get_state(ag)
{:memory, shared_mem} = :erlang.process_info(ag, :memory)
flat = :sys.get_state(ag) |> :erts_debug.flat_size()
IO.puts("B) compact-but-shared state (1000x shared 1MB chunk):")
IO.puts("   process_info(:memory) -> #{mb.(shared_mem)}  (what a size-gate sees -> PASSES)")
IO.puts("   flat_size of the copy -> #{mb.(flat*8)}  (what sys:get_state actually allocates)")
IO.puts("   => a memory gate misses sharing expansion by #{Float.round(flat*8/shared_mem,0)}x")
System.halt(0)
