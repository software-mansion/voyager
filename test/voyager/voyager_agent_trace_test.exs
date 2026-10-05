defmodule VoyagerAgentTraceTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, Voyager.Agent.module()}

  alias Voyager.Test.VoyagerAgentFixture

  @agent_module Voyager.Agent.module()
  @spec_args %{
    module: "Elixir.String",
    function: "jaro_distance",
    arity: 2,
    capture: :args,
    local: false
  }
  @limits %{max_events: 1_000, max_rate: 1_000, max_time_ms: 5_000, budget: 50}

  setup do
    VoyagerAgentFixture.load!()
    :ok
  end

  test "pushes calls with their arguments and stops at the event limit" do
    {:ok, tracer} = @agent_module.trace_start(self(), @spec_args, %{@limits | max_events: 3})

    for _ <- 1..5, do: String.jaro_distance("voyager", "voyage")

    assert {events, :event_limit, %{events: 3, dropped: 0}} = collect(tracer)
    assert [%{mfa: {String, :jaro_distance, 2}, args: ["voyager", "voyage"]} | _] = events
    assert length(events) == 3
  end

  test "arity capture sends no arguments" do
    spec = %{@spec_args | capture: :arity}
    {:ok, tracer} = @agent_module.trace_start(self(), spec, %{@limits | max_events: 1})

    String.jaro_distance("a", "b")

    assert {[event], :event_limit, _stats} = collect(tracer)
    assert %{mfa: {String, :jaro_distance, 2}, pid: pid} = event
    assert pid == self()
    refute Map.has_key?(event, :args)
  end

  test "stops when the rate limit is exceeded" do
    {:ok, tracer} = @agent_module.trace_start(self(), @spec_args, %{@limits | max_rate: 5})

    for _ <- 1..20, do: String.jaro_distance("a", "b")

    assert {_events, :rate_limit, %{events: 6}} = collect(tracer)
  end

  test "stops when the time limit runs out" do
    {:ok, tracer} = @agent_module.trace_start(self(), @spec_args, %{@limits | max_time_ms: 50})

    assert {[], :time_limit, %{events: 0}} = collect(tracer)
  end

  test "a stop message ends the trace and removes the session" do
    {:ok, tracer} = @agent_module.trace_start(self(), @spec_args, @limits)
    ref = Process.monitor(tracer)

    send(tracer, :voyager_trace_stop)

    assert {[], :stopped, _stats} = collect(tracer)
    assert_receive {:DOWN, ^ref, :process, ^tracer, :normal}
    refute Enum.any?(:trace.session_info(:all), &match?({:voyager, _}, &1))
  end

  test "stops when the collector goes down" do
    collector = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, tracer} = @agent_module.trace_start(collector, @spec_args, @limits)
    ref = Process.monitor(tracer)

    Process.exit(collector, :kill)

    assert_receive {:DOWN, ^ref, :process, ^tracer, :normal}
  end

  test "rejects specs it cannot or should not trace" do
    assert {:error, {:refused, :erlang}} =
             @agent_module.trace_start(self(), %{@spec_args | module: "erlang"}, @limits)

    assert {:error, :unknown_function} =
             @agent_module.trace_start(
               self(),
               %{@spec_args | module: "Elixir.NoSuchModule#{System.unique_integer()}"},
               @limits
             )

    assert {:error, :no_function_matched} =
             @agent_module.trace_start(self(), %{@spec_args | arity: 9}, @limits)
  end

  defp collect(tracer, acc \\ []) do
    receive do
      {:voyager_trace_events, ^tracer, events, _dropped} -> collect(tracer, acc ++ events)
      {:voyager_trace_done, ^tracer, reason, stats} -> {acc, reason, stats}
    after
      2_000 -> flunk("no trace messages, got #{inspect(acc)}")
    end
  end
end
