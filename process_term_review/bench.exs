# Red-team harness for Voyager.Services.ProcessTerm / voyager_agent term-bounding.
#
# Runs ONE scenario per OS process (so a scenario that kills the node is
# observable from outside) and prints a single RESULT line.
#
# The agent functions are invoked inside a spawned, monitored worker -- exactly
# how :erpc runs an MFA on the target node -- so max_heap_size(kill) lands on the
# ephemeral worker, matching production.

:code.add_patha(String.to_charlist(__DIR__))

defmodule Sampler do
  # Polls node-wide memory and OS RSS, tracking the peak, until stopped.
  def start do
    parent = self()
    pid = spawn(fn -> loop(parent, 0, 0) end)
    {:ok, pid}
  end

  def stop(pid) do
    ref = Process.monitor(pid)
    send(pid, {:stop, self()})

    receive do
      {:peak, mem, rss} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          1000 -> :ok
        end

        {mem, rss}
    after
      5000 -> {0, 0}
    end
  end

  defp loop(parent, max_mem, max_rss) do
    mem = :erlang.memory(:total)
    rss = read_rss()
    max_mem = max(max_mem, mem)
    max_rss = max(max_rss, rss)

    receive do
      {:stop, from} -> send(from, {:peak, max_mem, max_rss})
    after
      1 -> loop(parent, max_mem, max_rss)
    end
  end

  def read_rss do
    case File.read("/proc/self/status") do
      {:ok, bin} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, bin) do
          [_, kb] -> String.to_integer(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end
end

defmodule Bench do
  @mb 1024 * 1024

  # A list of K integers ~ 16*K bytes of heap. Sized so |x| ~ mb megabytes.
  def heap_chunk(mb), do: Enum.to_list(1..trunc(mb * @mb / 16))

  # ---- target builders. State builders run INSIDE the target via the init fun,
  # so any internal sharing lives on the target heap (not pre-expanded by us).

  def start_state_agent(build_fun) do
    {:ok, pid} = Agent.start(build_fun, [])
    _ = :sys.get_state(pid)
    pid
  end

  def start_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Fill a mailbox with `count` messages produced by `msg_fun.()`, without the
  # harness retaining copies.
  def fill_mailbox(pid, count, msg_fun) do
    Enum.each(1..count, fn _ -> send(pid, msg_fun.()) end)
    # ensure all delivered onto target heap
    :erlang.suspend_process(pid)
    :erlang.resume_process(pid)
    pid
  end

  def target_heap_bytes(pid) do
    case :erlang.process_info(pid, :memory) do
      {:memory, m} -> m
      _ -> 0
    end
  end

  # Run `fun` (calls the agent) inside a monitored worker, mirroring :erpc.
  def run_worker(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:returned, fun.()}
          catch
            kind, reason -> {:caught, kind, reason}
          end

        send(parent, {:worker_result, self(), result})
      end)

    receive do
      {:worker_result, ^pid, result} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          2000 -> :ok
        end

        result
    after
      120_000 ->
        Process.exit(pid, :kill)
        {:timeout, :worker}
    end
  end

  def classify({:returned, {:ok, %{truncated?: t}}}), do: "ok(truncated?=#{t})"
  def classify({:returned, {:ok, %{truncated: t}}}), do: "ok(truncated=#{t})"
  def classify({:returned, {:error, r}}), do: "error(#{inspect(r)})"
  def classify({:returned, other}), do: "returned(#{inspect(other, limit: 5)})"
  def classify({:caught, kind, reason}), do: "caught(#{kind}:#{inspect(reason, limit: 5)})"
  def classify({:worker_down, reason}), do: "worker_killed(#{inspect(reason, limit: 5)})"
  def classify(other), do: inspect(other, limit: 5)

  # spawn_monitor path: distinguish worker death (max_heap_size kill) from a
  # normal return. If the worker dies before sending a result, we get its DOWN.
  def run_worker_strict(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:worker_result, self(), {:returned, fun.()}})
      end)

    receive do
      {:worker_result, ^pid, result} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          2000 -> :ok
        end

        result

      {:DOWN, ^ref, _, _, reason} ->
        {:worker_down, reason}
    after
      120_000 ->
        Process.exit(pid, :kill)
        {:timeout, :worker}
    end
  catch
    _, _ -> {:worker_err}
  end
end

# ---------------------------------------------------------------------------

[scenario | rest] = System.argv()
_node_self = Node.self()
budget_default = 5000

parse = fn key, default ->
  case Enum.find(rest, fn a -> String.starts_with?(a, "#{key}=") end) do
    nil -> default
    a -> a |> String.split("=") |> List.last() |> String.to_integer()
  end
end

limit = parse.("limit", 200)
budget = parse.("budget", budget_default)
mb = parse.("mb", 100)
copies = parse.("copies", 1000)
count = parse.("count", 1000)
depth = parse.("depth", 100_000)

mem0 = :erlang.memory(:total)
rss0 = Sampler.read_rss()

{target, call, note} =
  case scenario do
    "msg_heap" ->
      # Mailbox of `count` messages, each ~ (mb/count) MB of heap term.
      per = mb / count
      pid = Bench.start_idle()
      Bench.fill_mailbox(pid, count, fn -> Bench.heap_chunk(per) end)
      {pid, fn -> :voyager_agent.proc_messages(pid, limit, budget) end,
       "mailbox ~#{mb}MB across #{count} msgs, limit=#{limit} budget=#{budget}"}

    "state_shared" ->
      # State = `copies` references to one shared ~mb-MB chunk (compact on
      # target, expands on copy).
      pid =
        Bench.start_state_agent(fn ->
          x = Bench.heap_chunk(mb)
          List.duplicate(x, copies)
        end)

      {pid, fn -> :voyager_agent.proc_state(pid, budget, 5000) end,
       "state = dup(#{mb}MB chunk, #{copies}x) shared, budget=#{budget}"}

    "state_flat" ->
      pid = Bench.start_state_agent(fn -> Bench.heap_chunk(mb) end)

      {pid, fn -> :voyager_agent.proc_state(pid, budget, 5000) end,
       "state = flat #{mb}MB term, budget=#{budget}"}

    "dict_shared" ->
      pid =
        Bench.start_state_agent(fn ->
          x = Bench.heap_chunk(mb)
          Enum.each(1..copies, fn i -> Process.put(i, x) end)
          :ok
        end)

      {pid, fn -> :voyager_agent.proc_dictionary(pid, limit, budget) end,
       "dict = #{copies} entries sharing #{mb}MB chunk, limit=#{limit} budget=#{budget}"}

    "label_shared" ->
      pid =
        Bench.start_state_agent(fn ->
          x = Bench.heap_chunk(mb)
          :proc_lib.set_label(List.duplicate(x, copies))
          :ok
        end)

      {pid, fn -> :voyager_agent.proc_label(pid, budget) end,
       "label = dup(#{mb}MB chunk, #{copies}x) shared, budget=#{budget}"}

    "deep" ->
      # Deeply nested list to probe walk/3 recursion under a big budget.
      pid =
        Bench.start_state_agent(fn ->
          Enum.reduce(1..depth, [], fn _, acc -> [acc] end)
        end)

      {pid, fn -> :voyager_agent.proc_state(pid, budget, 5000) end,
       "state = list nested #{depth} deep, budget=#{budget}"}

    "funs_shared" ->
      # State = list of `copies` funs all capturing one shared mb-MB chunk;
      # walk_uncuttable calls external_size on each -> CPU amplification.
      pid =
        Bench.start_state_agent(fn ->
          x = Bench.heap_chunk(mb)
          Enum.map(1..copies, fn _ -> fn -> x end end)
        end)

      {pid, fn -> :voyager_agent.proc_state(pid, budget, 5000) end,
       "state = #{copies} funs sharing #{mb}MB chunk, budget=#{budget}"}

    other ->
      IO.puts("unknown scenario #{other}")
      System.halt(2)
  end

target_heap = Bench.target_heap_bytes(target)
:erlang.garbage_collect()
{:ok, sampler} = Sampler.start()
t0 = System.monotonic_time(:millisecond)
result = Bench.run_worker_strict(call)
t1 = System.monotonic_time(:millisecond)
{peak_mem, peak_rss} = Sampler.stop(sampler)

# node still alive if we got here
mem1 = :erlang.memory(:total)

fmt = fn b -> :erlang.float_to_binary(b / (1024 * 1024), decimals: 1) <> "MB" end

IO.puts("""
RESULT scenario=#{scenario} #{note}
  target_heap=#{fmt.(target_heap)} baseline_mem=#{fmt.(mem0)} baseline_rss=#{fmt.(rss0)}
  peak_mem=#{fmt.(peak_mem)} peak_rss=#{fmt.(peak_rss)} after_mem=#{fmt.(mem1)}
  delta_peak_mem=#{fmt.(peak_mem - mem0)} delta_peak_rss=#{fmt.(peak_rss - rss0)}
  elapsed_ms=#{t1 - t0} outcome=#{Bench.classify(result)} node_alive=true
""")

System.halt(0)
