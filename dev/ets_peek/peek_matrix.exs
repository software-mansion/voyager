# Manual test harness for the ETS records API (Voyager.Services.Ets.{Remote,Fetch,Sanitize}).
#
#     epmd -daemon
#     MIX_ENV=test mix run dev/ets_peek/peek_matrix.exs
#
# Starts a real peer node so continuations and record payloads actually cross
# external term format, which `Node.self()` tests cannot exercise. A stand-in
# `:voyager_agent` implementing the VOY-230 contract is loaded on the peer to
# cover the agent path before that module exists.

defmodule Peek.Report do
  def section(title), do: IO.puts("\n\e[1;36m#{title}\e[0m")

  def row(label, value),
    do:
      IO.puts(
        "  #{String.pad_trailing(label, 48)} #{inspect(value, limit: 8, printable_limit: 60)}"
      )

  def check(label, true), do: IO.puts("  \e[32mPASS\e[0m #{label}")
  def check(label, false), do: IO.puts("  \e[31mFAIL\e[0m #{label}")
  def note(label), do: IO.puts("  \e[33mNOTE\e[0m #{label}")
end

defmodule Peek.Peer do
  @setup ~S'''
  defmodule PeerSetup do
    def start_owner do
      pid = spawn(fn -> loop() end)
      Process.register(pid, :voyager_table_owner)
      pid
    end

    def new(name, opts), do: call({:new, name, opts})
    def insert(tid, rows), do: call({:insert, tid, rows})

    # Built on the target so the host never holds the payload before the read.
    def insert_blob(tid, key, bytes), do: call({:insert, tid, {key, :binary.copy("x", bytes)}})
    def insert_seq(tid, key, count), do: call({:insert, tid, {key, :lists.seq(1, count)}})

    defp call(msg) do
      send(:voyager_table_owner, Tuple.insert_at(msg, 1, self()))

      receive do
        {:reply, value} -> value
      after
        60_000 -> {:error, :timeout}
      end
    end

    defp loop do
      receive do
        {:new, from, name, opts} ->
          send(from, {:reply, :ets.new(name, opts)})
          loop()

        {:insert, from, tid, rows} ->
          :ets.insert(tid, rows)
          send(from, {:reply, :ets.info(tid, :size)})
          loop()

        :stop ->
          :ok
      end
    end
  end
  '''

  # Minimal VOY-230 contract: one-shot worker, bounded heap, target-side
  # truncate to 512 / 50 / 5, repair_continuation + select in one call.
  @agent ~S'''
  defmodule :voyager_agent do
    @max_bin 512
    @max_coll 50
    @max_depth 5
    @match_all [{:"$1", [], [:"$1"]}]

    def ets_select_chunk(table, limit, :undefined),
      do: bounded(fn -> page(:ets.select(table, @match_all, limit)) end)

    def ets_select_chunk(_table, _limit, cont),
      do: bounded(fn -> page(:ets.select(:ets.repair_continuation(cont, @match_all))) end)

    def ets_lookup(table, key),
      do: bounded(fn -> Enum.map(:ets.lookup(table, key), &truncate(&1, 0)) end)

    defp page(:"$end_of_table"), do: :"$end_of_table"
    defp page({records, cont}), do: {Enum.map(records, &truncate(&1, 0)), cont}

    defp bounded(fun) do
      parent = self()
      ref = make_ref()

      {pid, mref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: 500_000, kill: true})

          try do
            send(parent, {ref, {:ok, fun.()}})
          catch
            kind, reason -> send(parent, {ref, {:raise, kind, reason, __STACKTRACE__}})
          end
        end)

      receive do
        {^ref, {:ok, result}} -> Process.demonitor(mref, [:flush]) && result
        {^ref, {:raise, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
        {:DOWN, ^mref, :process, ^pid, reason} -> :erlang.error({:agent_worker_down, reason})
      after
        15_000 -> :erlang.error(:agent_timeout)
      end
    end

    defp truncate(bin, _depth) when is_binary(bin) and byte_size(bin) > @max_bin do
      {:"$voyager_truncated", :binary, :binary.copy(binary_part(bin, 0, @max_bin)), byte_size(bin)}
    end

    defp truncate(term, depth)
         when depth >= @max_depth and (is_list(term) or is_map(term) or is_tuple(term)) do
      if empty?(term), do: term, else: {:"$voyager_truncated", :depth}
    end

    defp truncate(list, depth) when is_list(list) do
      kept = Enum.take(list, @max_coll)
      omitted = length(list) - length(kept)
      sanitized = Enum.map(kept, &truncate(&1, depth + 1))
      if omitted > 0, do: {:"$voyager_truncated", :list, sanitized, omitted}, else: sanitized
    end

    defp truncate(map, depth) when is_map(map) do
      pairs = map |> Map.to_list() |> Enum.sort()
      kept = Enum.take(pairs, @max_coll)
      omitted = length(pairs) - length(kept)
      sanitized = Enum.map(kept, fn {k, v} -> {truncate(k, depth + 1), truncate(v, depth + 1)} end)
      if omitted > 0, do: {:"$voyager_truncated", :map, sanitized, omitted}, else: Map.new(sanitized)
    end

    defp truncate(tuple, depth) when is_tuple(tuple) do
      size = tuple_size(tuple)
      kept = tuple |> Tuple.to_list() |> Enum.take(@max_coll) |> Enum.map(&truncate(&1, depth + 1))

      if size > @max_coll,
        do: {:"$voyager_truncated", :tuple, kept, size - @max_coll},
        else: List.to_tuple(kept)
    end

    defp truncate(term, _depth), do: term

    defp empty?([]), do: true
    defp empty?({}), do: true
    defp empty?(map) when is_map(map), do: map_size(map) == 0
    defp empty?(_), do: false
  end
  '''

  def start! do
    {:ok, _} = :net_kernel.start([:"voyager_peek_host@127.0.0.1", :longnames])

    {:ok, _pid, node} =
      :peer.start_link(%{
        name: :ets_peek_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        wait_boot: 30_000,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    load(node, @setup)
    :erpc.call(node, PeerSetup, :start_owner, [], 30_000)
    node
  end

  def load_agent(node), do: load(node, @agent)

  defp load(node, source) do
    for {module, binary} <- Code.compile_string(source) do
      {:module, ^module} =
        :erpc.call(node, :code, :load_binary, [module, ~c"nofile", binary], 30_000)
    end
  end
end

alias Peek.Peer
alias Peek.Report
alias Voyager.Services.Ets.Fetch
alias Voyager.Services.Ets.Remote
alias Voyager.Services.Ets.Sanitize

node = Peer.start!()
Voyager.Erpc.bind_impl(Voyager.Erpc.Impl)

new = fn name, opts -> :erpc.call(node, PeerSetup, :new, [name, opts], 30_000) end
insert = fn tid, rows -> :erpc.call(node, PeerSetup, :insert, [tid, rows], 120_000) end

mb = fn ->
  :erlang.garbage_collect()
  div(:erlang.memory(:total), 1_048_576)
end

Report.section("Table options: info/3 and list/2")

variants = [
  {:pk_set, [:named_table, :public, :set]},
  {:pk_ordered_set, [:named_table, :public, :ordered_set]},
  {:pk_bag, [:named_table, :public, :bag]},
  {:pk_duplicate_bag, [:named_table, :public, :duplicate_bag]},
  {:pk_protected, [:named_table, :protected, :set]},
  {:pk_private, [:named_table, :private, :set]},
  {:pk_unnamed, [:public, :set]},
  {:pk_unnamed_private, [:private, :ordered_set]},
  {:pk_unnamed_bag, [:protected, :bag]},
  {:pk_private_dbag, [:named_table, :private, :duplicate_bag]},
  {:pk_keypos2, [:named_table, :public, :set, {:keypos, 2}]},
  {:pk_keypos3, [:named_table, :public, :duplicate_bag, {:keypos, 3}]},
  {:pk_compressed, [:named_table, :public, :set, :compressed]},
  {:pk_read_conc, [:named_table, :public, :set, {:read_concurrency, true}]},
  {:pk_write_conc, [:named_table, :public, :set, {:write_concurrency, true}]},
  {:pk_write_auto, [:named_table, :public, :set, {:write_concurrency, :auto}]},
  {:pk_dec_counters,
   [
     :named_table,
     :public,
     :ordered_set,
     {:write_concurrency, true},
     {:decentralized_counters, true}
   ]}
]

handles = Map.new(variants, fn {name, opts} -> {name, new.(name, opts)} end)
{:ok, listed} = Remote.list(node, 15_000)
listed_ids = MapSet.new(listed, & &1.id)

for {name, _opts} <- variants do
  handle = handles[name]

  case Remote.info(node, handle, 15_000) do
    {:ok, info} ->
      Report.check(
        "#{String.pad_trailing(to_string(name), 20)} type=#{String.pad_trailing(to_string(info.type), 14)}" <>
          " prot=#{String.pad_trailing(to_string(info.protection), 10)} keypos=#{info.keypos}" <>
          " compressed=#{String.pad_trailing(to_string(info.compressed), 6)} wc=#{inspect(info.write_concurrency)}",
        MapSet.member?(listed_ids, handle)
      )

    error ->
      Report.row("#{name} info/3", error)
  end
end

Report.check("private tables are listed", Enum.any?(listed, &(&1.protection == :private)))

Report.section("Records per table type (MFA path)")

for {label, opts, rows, expected} <- [
      {:set, [:set], Enum.map(1..25, &{&1, &1}), 25},
      {:ordered_set, [:ordered_set], Enum.map(1..25, &{&1, &1}), 25},
      {:bag, [:bag], Enum.flat_map(1..13, &[{&1, :a}, {&1, :b}]), 26},
      {:duplicate_bag, [:duplicate_bag], List.duplicate({:k, :v}, 25), 25}
    ] do
  table = :"rec_#{label}"
  new.(table, [:named_table, :public | opts])
  size = insert.(table, rows)
  {:ok, chunk} = Fetch.select_chunk(node, table, 10, nil, 15_000)

  Report.check(
    "#{label}: size #{size} == #{expected}, first page of 10, via :mfa",
    size == expected and length(chunk.records) == 10 and chunk.via == :mfa
  )
end

Report.section("Continuation at the end of the table")

for rows <- [0, 3, 10, 11] do
  table = :"cont_#{rows}"
  new.(table, [:named_table, :public, :set])
  if rows > 0, do: insert.(table, Enum.map(1..rows, &{&1, &1}))
  {:ok, chunk} = Remote.select_chunk(node, table, 10, nil, 15_000)
  exhausted? = rows <= 10

  Report.check(
    "#{rows} rows at limit 10: continuation is nil when exhausted",
    is_nil(chunk.continuation) == exhausted?
  )

  Report.row("  continuation", chunk.continuation)
end

Report.section("Paging: MFA refuses, the agent drains")

new.(:page_src, [:named_table, :public, :set])
insert.(:page_src, Enum.map(1..25, &{&1, &1}))
{:ok, first} = Fetch.select_chunk(node, :page_src, 10, nil, 15_000)

Report.check(
  "MFA continuation is :cannot_page",
  Fetch.select_chunk(node, :page_src, 10, first.continuation, 15_000) == {:error, :cannot_page}
)

Report.note("repair_continuation/2 and select/1 must run in ONE remote call:")

repaired =
  :erpc.call(
    node,
    :ets,
    :repair_continuation,
    [first.continuation, [{:"$1", [], [:"$1"]}]],
    15_000
  )

Report.row(
  "  repaired on target, then select in a second call",
  try do
    :erpc.call(node, :ets, :select, [repaired], 15_000)
  catch
    kind, reason -> {kind, reason}
  end
)

Peer.load_agent(node)

drain = fn table, limit ->
  Enum.reduce_while(1..20, {nil, [], 0}, fn _, {cont, acc, calls} ->
    case Fetch.select_chunk(node, table, limit, cont, 20_000) do
      {:ok, %{records: records, continuation: nil}} -> {:halt, {:done, acc ++ records, calls + 1}}
      {:ok, %{records: records, continuation: cont}} -> {:cont, {cont, acc ++ records, calls + 1}}
      {:error, reason} -> {:halt, {{:error, reason}, acc, calls + 1}}
    end
  end)
end

for {label, expected} <- [{:set, 25}, {:ordered_set, 25}, {:bag, 26}, {:duplicate_bag, 25}] do
  {status, records, calls} = drain.(:"rec_#{label}", 10)

  Report.check(
    "agent drains #{label}: #{length(records)}/#{expected} rows in #{calls} calls, no skips or duplicates",
    status == :done and length(records) == expected
  )
end

{:ok, ordered} = Fetch.select_chunk(node, :rec_ordered_set, 10, nil, 15_000)
keys = Enum.map(ordered.records, &elem(&1, 0))
Report.check("ordered_set page keeps key order", keys == Enum.sort(keys))

Report.section("Errors")

new.(:err_gone, [:named_table, :public, :set])
gone_tid = new.(:err_gone_unnamed, [:public, :set])
:erpc.call(node, :ets, :delete, [:err_gone], 15_000)
:erpc.call(node, :ets, :delete, [gone_tid], 15_000)
new.(:err_private, [:named_table, :private, :set])

for {label, result, expected} <- [
      {"private table select", Fetch.select_chunk(node, :err_private, 10, nil, 15_000),
       {:error, :cannot_read}},
      {"private table lookup", Fetch.lookup(node, :err_private, :k, 15_000),
       {:error, :cannot_read}},
      {"deleted named table", Fetch.select_chunk(node, :err_gone, 10, nil, 15_000),
       {:error, :cannot_read}},
      {"deleted unnamed table", Fetch.select_chunk(node, gone_tid, 10, nil, 15_000),
       {:error, :cannot_read}},
      {"pid as a handle", Fetch.select_chunk(node, self(), 10, nil, 15_000),
       {:error, :invalid_table}},
      {"limit 25", Fetch.select_chunk(node, :rec_set, 25, nil, 15_000), {:error, :invalid_limit}},
      {"tuple key", Fetch.lookup(node, :rec_set, {1, 2}, 15_000), {:error, :invalid_key}},
      {"float key", Fetch.lookup(node, :rec_set, 1.5, 15_000), {:error, :invalid_key}}
    ] do
  Report.check("#{label} -> #{inspect(expected)}", result == expected)
end

Report.section("Host bounds on the MFA path (every real node until VOY-230)")

# The stand-in agent truncates on the target, which hides what the host has to
# absorb when it is not there. Bounds are only meaningful with the agent gone.
purge_agent = fn ->
  :erpc.call(node, :code, :purge, [:voyager_agent], 15_000)
  :erpc.call(node, :code, :delete, [:voyager_agent], 15_000)
  :erpc.call(node, :code, :purge, [:voyager_agent], 15_000)
end

purge_agent.()

peak_while = fn fun ->
  sampler =
    spawn(fn ->
      watch = fn watch, peak ->
        receive do
          {:stop, from} -> send(from, {:peak, peak})
        after
          5 -> watch.(watch, max(peak, :erlang.memory(:total)))
        end
      end

      watch.(watch, :erlang.memory(:total))
    end)

  before = mb.()
  result = fun.()
  send(sampler, {:stop, self()})
  peak = receive do: ({:peak, bytes} -> div(bytes, 1_048_576)), after: (5_000 -> 0)
  {result, before, peak, mb.()}
end

new.(:bound_dbag, [:named_table, :public, :duplicate_bag])
insert.(:bound_dbag, List.duplicate({:hot, :ok}, 3_000))
{:ok, unbounded} = Fetch.lookup(node, :bound_dbag, :hot, 30_000)
Report.check("duplicate_bag lookup respects a 10/20/50 chunk", length(unbounded.records) <= 50)
Report.row("  records returned for one key", length(unbounded.records))

new.(:bound_binary, [:named_table, :public, :set])
:erpc.call(node, PeerSetup, :insert_blob, [:bound_binary, :blob, 200_000_000], 180_000)

{capped, before_mb, peak_mb, after_mb} =
  peak_while.(fn -> Fetch.lookup(node, :bound_binary, :blob, 120_000) end)

Report.check("200MB binary row does not balloon the host VM", peak_mb - before_mb < 100)
Report.row("  host MB before / peak / after", {before_mb, peak_mb, after_mb})

Report.row(
  "  record returned",
  case capped do
    {:ok, chunk} -> chunk.records
    error -> error
  end
)

new.(:bound_list, [:named_table, :public, :set])
:erpc.call(node, PeerSetup, :insert_seq, [:bound_list, :wide, 2_000_000], 120_000)

Report.check(
  "2M-cons-cell row is a clean heap kill",
  Fetch.lookup(node, :bound_list, :wide, 120_000) == {:error, :heap_limit_exceeded}
)

Peer.load_agent(node)

{agent_capped, _before, agent_peak, _after} =
  peak_while.(fn -> Fetch.lookup(node, :bound_binary, :blob, 120_000) end)

Report.note("same two rows with the agent present (target-side truncate):")
Report.row("  200MB binary row, host peak MB", agent_peak)

Report.row(
  "  200MB binary row via :agent",
  case agent_capped do
    {:ok, chunk} -> chunk.via
    error -> error
  end
)

Report.row(
  "  2M-cons-cell row via :agent",
  case Fetch.lookup(node, :bound_list, :wide, 120_000) do
    {:ok, chunk} -> {chunk.via, chunk.records}
    error -> error
  end
)

Report.section("Cost per read (microseconds, mean of 50)")

new.(:cost, [:named_table, :public, :set])
insert.(:cost, Enum.map(1..1000, &{&1, :binary.copy("v", 100)}))
purge_agent.()

mean = fn fun ->
  Enum.map(1..50, fn _ -> elem(:timer.tc(fun), 0) end) |> Enum.sum() |> div(50)
end

Report.row(
  "erpc function_exported probe",
  mean.(fn ->
    :erpc.call(node, :erlang, :function_exported, [:voyager_agent, :ets_select_chunk, 3], 15_000)
  end)
)

Report.row(
  "erpc :ets.select limit 10",
  mean.(fn -> :erpc.call(node, :ets, :select, [:cost, [{:"$1", [], [:"$1"]}], 10], 15_000) end)
)

Report.row(
  "Remote.select_chunk (probe + read)",
  mean.(fn -> Remote.select_chunk(node, :cost, 10, nil, 15_000) end)
)

Report.row(
  "Fetch.select_chunk (+ task + sanitize)",
  mean.(fn -> Fetch.select_chunk(node, :cost, 10, nil, 15_000) end)
)

for keys <- [50, 5_000, 200_000] do
  map = Map.new(1..keys, &{&1, &1})

  Report.row(
    "Sanitize.term/1 on a #{keys}-key map",
    elem(:timer.tc(fn -> Sanitize.term(map) end), 0)
  )
end

System.halt(0)
