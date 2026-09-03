# Drives ProcessTerm fetches through the real Voyager RateLimiter to measure how
# admission budgets bound (or fail to bound) the load on the observed node.
#
# One (config x per-request-cost x clients) point per OS process -> one RLRESULT.
#
# Key subtlety under test: RateLimiter.run/3 runs the work in the CALLER, so the
# bucket caps request *rate*, not *concurrency* or *cost*. `high_capacity` is a
# burst of simultaneous admissions; each admitted request can be arbitrarily
# expensive.

:code.add_patha(String.to_charlist(__DIR__))
[_ | _] = Code.compile_file("/home/user/voyager/lib/voyager/services/rate_limiter.ex")

alias Voyager.Services.RateLimiter

defmodule RL do
  def heap_chunk(mb), do: Enum.to_list(1..trunc(mb * 1_048_576 / 16))

  def make_state_target(mb, share) do
    build =
      if share > 0 do
        fn -> List.duplicate(heap_chunk(1), share) end
      else
        fn -> heap_chunk(mb) end
      end

    {:ok, pid} = Agent.start(build, [])
    _ = :sys.get_state(pid)
    pid
  end

  # One term fetch, in a monitored sub-worker (as :erpc would), so a max_heap
  # kill is contained. Returns :done | :killed.
  def fetch(target, budget) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        _ = :voyager_agent.proc_state(target, budget, 5000)
        send(parent, {:ok, self()})
      end)

    receive do
      {:ok, ^pid} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          2000 -> :ok
        end

        :done

      {:DOWN, ^ref, _, _, _} ->
        :killed
    after
      60_000 -> :timeout
    end
  end
end

defmodule Sampler do
  def start do
    pid = spawn(fn -> loop(0, 0, 0) end)
    {:ok, pid}
  end

  def stop(pid) do
    ref = Process.monitor(pid)
    send(pid, {:stop, self()})

    receive do
      {:peak, mem, rss, stall} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          1000 -> :ok
        end

        {mem, rss, stall}
    after
      5000 -> {0, 0, 0}
    end
  end

  defp loop(max_mem, max_rss, max_stall) do
    t = System.monotonic_time(:millisecond)
    mem = :erlang.memory(:total)
    rss = read_rss()

    receive do
      {:stop, from} -> send(from, {:peak, max(max_mem, mem), max(max_rss, rss), max_stall})
    after
      1 ->
        stall = System.monotonic_time(:millisecond) - t - 1
        loop(max(max_mem, mem), max(max_rss, rss), max(max_stall, stall))
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

parse = fn args, key, default ->
  case Enum.find(args, fn a -> String.starts_with?(a, "#{key}=") end) do
    nil -> default
    a -> a |> String.split("=") |> List.last() |> String.to_integer()
  end
end

args = System.argv()
cap = parse.(args, "cap", 10)
refill = parse.(args, "refill", 5)
clients = parse.(args, "clients", 16)
cost_mb = parse.(args, "cost", 20)
share = parse.(args, "share", 0)
dur_ms = parse.(args, "dur", 3000)
budget = parse.(args, "budget", 5000)

config = %{
  high_capacity: cap,
  high_refill: refill,
  low_capacity: 2,
  low_refill: 1,
  low_starvation_threshold: 2,
  refill_interval_ms: 1_000
}

{:ok, _} = RateLimiter.start_link(config: config, name: :bench_rl)

# One distinct target per client so admitted copies actually overlap.
targets = for _ <- 1..clients, do: RL.make_state_target(cost_mb, share)
:erlang.garbage_collect()
mem0 = :erlang.memory(:total)
rss0 = Sampler.read_rss()

parent = self()
{:ok, sampler} = Sampler.start()
deadline = System.monotonic_time(:millisecond) + dur_ms

runner = fn target ->
  spawn(fn ->
    loop = fn loop, admitted, throttled ->
      if System.monotonic_time(:millisecond) >= deadline do
        send(parent, {:stats, admitted, throttled})
      else
        case RateLimiter.run(:bench_rl, :high, fn -> RL.fetch(target, budget) end) do
          {:ok, _res, _us} -> loop.(loop, admitted + 1, throttled)
          {:error, :rate_limited, wait} ->
            Process.sleep(max(wait, 5))
            loop.(loop, admitted, throttled + 1)
        end
      end
    end

    loop.(loop, 0, 0)
  end)
end

Enum.each(targets, runner)

{admitted, throttled} =
  Enum.reduce(1..clients, {0, 0}, fn _, {a, t} ->
    receive do
      {:stats, ca, ct} -> {a + ca, t + ct}
    after
      120_000 -> {a, t}
    end
  end)

{peak_mem, peak_rss, worst_stall} = Sampler.stop(sampler)
secs = dur_ms / 1000
fmt = fn b -> :erlang.float_to_binary(b / 1_048_576, decimals: 0) <> "MB" end

IO.puts("""
RLRESULT cap=#{cap} refill=#{refill} clients=#{clients} percopy=#{if share>0, do: "#{share}MB(shared)", else: "#{cost_mb}MB(flat)"} budget=#{budget}
  admitted=#{admitted} throttled=#{throttled} throughput=#{Float.round(admitted / secs, 1)}/s
  peak_mem=#{fmt.(peak_mem)} Δpeak_mem=#{fmt.(peak_mem - mem0)} Δpeak_rss=#{fmt.(peak_rss - rss0)}
  worst_stall_ms=#{worst_stall}
""")

System.halt(0)
