# Measures scheduler responsiveness (a "slow machine" = single scheduler) while
# one ProcessTerm fetch runs in a worker. A heartbeat process records the worst
# lateness of a 5ms timer; large lateness == the node is stalled for everyone.

:code.add_patha(String.to_charlist(__DIR__))

defmodule HB do
  # Loops firing a 5ms timer, tracking the worst overshoot (scheduler stall).
  def start(ms) do
    parent = self()
    pid = spawn(fn -> loop(parent, ms, 0, 0) end)
    {:ok, pid}
  end

  def stop(pid) do
    send(pid, {:stop, self()})

    receive do
      {:stalled, worst, ticks} -> {worst, ticks}
    after
      5000 -> {-1, -1}
    end
  end

  defp loop(parent, ms, worst, ticks) do
    t = System.monotonic_time(:millisecond)

    receive do
      {:stop, from} ->
        send(from, {:stalled, worst, ticks})
    after
      ms ->
        gap = System.monotonic_time(:millisecond) - t - ms
        loop(parent, ms, max(worst, gap), ticks + 1)
    end
  end
end

[scenario | rest] = System.argv()

parse = fn key, default ->
  case Enum.find(rest, fn a -> String.starts_with?(a, "#{key}=") end) do
    nil -> default
    a -> a |> String.split("=") |> List.last() |> String.to_integer()
  end
end

copies = parse.("copies", 5000)
budget = parse.("budget", 5000)
mb = parse.("mb", 4)

target =
  case scenario do
    "funs_binary" ->
      # State = `copies` funs all capturing ONE shared refc binary of `mb` MB.
      # The state copy stays small (binary shared by reference), but walk_uncuttable
      # calls external_size on each fun, and external_size charges the captured
      # binary's full payload -> O(mb) work per fun, up to `budget` funs.
      {:ok, pid} =
        Agent.start(
          fn ->
            x = :crypto.strong_rand_bytes(mb * 1024 * 1024)
            Enum.map(1..copies, fn _ -> fn -> x end end)
          end,
          []
        )

      _ = :sys.get_state(pid)
      pid

    "state_shared_dup" ->
      # Heap chunk shared `copies` times -> the state copy expands on the wire,
      # so this measures the scheduler stall of the raw copy (not the walk).
      {:ok, pid} =
        Agent.start(
          fn ->
            x = Enum.to_list(1..trunc(mb * 1024 * 1024 / 16))
            List.duplicate(x, copies)
          end,
          []
        )

      _ = :sys.get_state(pid)
      pid

    "bignum_list" ->
      # State = list of `copies` distinct bignums; each hits walk_uncuttable's
      # external_size branch.
      {:ok, pid} =
        Agent.start(
          fn ->
            base = Bitwise.bsl(1, mb * 8 * 1024)
            Enum.map(1..copies, fn i -> base + i end)
          end,
          []
        )

      _ = :sys.get_state(pid)
      pid
  end

target_mem =
  case :erlang.process_info(target, :memory) do
    {:memory, m} -> m
    _ -> 0
  end

parent = self()

worker = fn ->
  {pid, ref} =
    spawn_monitor(fn ->
      send(parent, {:done, self(), :voyager_agent.proc_state(target, budget, 5000)})
    end)

  receive do
    {:done, ^pid, r} -> {:ok, r}
    {:DOWN, ^ref, _, _, reason} -> {:down, reason}
  after
    120_000 -> {:timeout}
  end
end

{:ok, hb} = HB.start(5)
t0 = System.monotonic_time(:millisecond)
{cpu_us, res} = :timer.tc(worker)
t1 = System.monotonic_time(:millisecond)
{worst, ticks} = HB.stop(hb)

fmt = fn b -> :erlang.float_to_binary(b / (1024 * 1024), decimals: 1) <> "MB" end

outcome =
  case res do
    {:ok, {:ok, %{truncated: t}}} -> "ok(truncated=#{t})"
    {:ok, other} -> "ok(#{inspect(other, limit: 3)})"
    {:down, reason} -> "worker_killed(#{inspect(reason, limit: 3)})"
    other -> inspect(other, limit: 3)
  end

schedulers = :erlang.system_info(:schedulers_online)

IO.puts("""
CPURESULT scenario=#{scenario} schedulers_online=#{schedulers} copies=#{copies} mb=#{mb} budget=#{budget}
  target_mem=#{fmt.(target_mem)} elapsed_ms=#{t1 - t0} cpu_wall_ms=#{div(cpu_us, 1000)}
  heartbeat_worst_stall_ms=#{worst} heartbeat_ticks=#{ticks} outcome=#{outcome}
""")

System.halt(0)
