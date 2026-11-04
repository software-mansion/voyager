defmodule VoyagerAgentTraceTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, Voyager.Agent.module()}

  alias Voyager.Test.VoyagerAgentFixture

  @agent_module Voyager.Agent.module()
  @leap_year [module: "Elixir.Date", function: "leap_year?", arity: 1]
  @limits %{max_events: 1_000, max_rate: 1_000, max_time_ms: 5_000, budget: 50}

  setup do
    VoyagerAgentFixture.load!()
    Code.ensure_loaded!(Date)
    :ok
  end

  test "pushes calls with their arguments and stops at the event limit" do
    {:ok, tracer} = start(spec(), %{@limits | max_events: 3})

    for _ <- 1..5, do: String.jaro_distance("voyager", "voyage")

    assert {events, :event_limit, %{events: 3, dropped: 0}} = collect(tracer)

    assert [%{type: :call, mfa: {String, :jaro_distance, 2}, args: ["voyager", "voyage"]} | _] =
             events

    assert length(events) == 3
  end

  test "arity capture sends no arguments" do
    {:ok, tracer} = start(spec(capture: :arity), %{@limits | max_events: 1})

    String.jaro_distance("a", "b")

    assert {[event], :event_limit, _stats} = collect(tracer)
    assert %{type: :call, mfa: {String, :jaro_distance, 2}, pid: pid, at: at} = event
    assert pid == self()
    assert_in_delta at, System.os_time(:microsecond), 1_000_000
    refute Map.has_key?(event, :args)
  end

  test "stops when the rate limit is exceeded" do
    {:ok, tracer} = start(spec(), %{@limits | max_rate: 5})

    for _ <- 1..20, do: String.jaro_distance("a", "b")

    assert {_events, :rate_limit, %{events: 6}} = collect(tracer)
  end

  test "stops when the time limit runs out" do
    {:ok, tracer} = start(spec(), %{@limits | max_time_ms: 50})

    assert {[], :time_limit, %{events: 0}} = collect(tracer)
  end

  test "stops at the event limit when it is the only limit given" do
    {:ok, tracer} = start(spec(), %{max_events: 2, budget: 50})

    for _ <- 1..5, do: String.jaro_distance("a", "b")

    assert {[_, _], :event_limit, %{events: 2}} = collect(tracer)
  end

  test "stops when the collector goes down" do
    collector = start_supervised!({Agent, fn -> nil end})
    {:ok, tracer} = start(spec(), @limits, collector)
    ref = Process.monitor(tracer)

    :ok = stop_supervised!(Agent)

    assert_receive {:DOWN, ^ref, :process, ^tracer, :normal}
  end

  test "a pid list traces only the listed processes" do
    other = start_supervised!({Agent, fn -> nil end})
    {:ok, tracer} = start(spec(), %{@limits | max_events: 1})

    Agent.get(other, fn _ -> String.jaro_distance("other", "x") end)
    String.jaro_distance("mine", "x")

    assert {[event], :event_limit, _stats} = collect(tracer)
    assert %{args: ["mine", "x"], pid: pid} = event
    assert pid == self()
  end

  test "all processes traces calls from any process" do
    other = start_supervised!({Agent, fn -> nil end})

    {:ok, tracer} =
      start(
        spec(module: "Elixir.Date", function: "leap_year?", arity: 1, processes: :all),
        %{@limits | max_events: 1}
      )

    Agent.get(other, fn _ -> Date.leap_year?(~D[2024-01-01]) end)

    assert {[%{type: :call, mfa: {Date, :leap_year?, 1}, pid: ^other}], :event_limit, _stats} =
             collect(tracer)
  end

  test "existing processes skips processes spawned after the start" do
    {:ok, tracer} = start(spec(@leap_year ++ [processes: :existing]), %{@limits | max_events: 1})
    later = start_supervised!({Agent, fn -> nil end})

    Agent.get(later, fn _ -> Date.leap_year?(~D[2024-01-01]) end)
    Date.leap_year?(~D[2024-01-01])

    assert {[%{pid: pid}], :event_limit, _stats} = collect(tracer)
    assert pid == self()
  end

  test "new processes skips processes that existed before the start" do
    {:ok, tracer} = start(spec(@leap_year ++ [processes: :new]), %{@limits | max_events: 1})
    later = start_supervised!({Agent, fn -> nil end})

    Date.leap_year?(~D[2024-01-01])
    Agent.get(later, fn _ -> Date.leap_year?(~D[2024-01-01]) end)

    assert {[%{pid: ^later}], :event_limit, _stats} = collect(tracer)
  end

  test "labels stay correct across more callers than the label cache holds" do
    callers = 600
    {:ok, tracer} = start(spec(@leap_year ++ [processes: :new]), %{@limits | max_events: callers})

    names =
      Map.new(1..callers, fn i ->
        name = :"voyager_trace_label_#{i}"
        start = {Agent, :start_link, [fn -> nil end, [name: name]]}
        {start_supervised!(%{id: name, start: start}), name}
      end)

    for name <- Map.values(names),
        do: Agent.get(name, fn _ -> Date.leap_year?(~D[2024-01-01]) end)

    assert {events, :event_limit, _stats} = collect(tracer)
    assert Enum.all?(events, fn %{pid: pid, process: label} -> label == names[pid] end)
  end

  test "return trace pairs a call with its return value" do
    {:ok, tracer} = start(spec(return_trace: true), %{@limits | max_events: 2})

    String.jaro_distance("a", "a")

    assert {[call, return], :event_limit, _stats} = collect(tracer)
    assert %{type: :call, mfa: {String, :jaro_distance, 2}, args: ["a", "a"]} = call
    assert %{type: :return, mfa: {String, :jaro_distance, 2}, value: 1.0} = return
  end

  test "return trace reports a raising call as an exception" do
    {:ok, tracer} =
      start(
        spec(module: "Elixir.Date", function: "from_iso8601!", arity: 1, return_trace: true),
        %{@limits | max_events: 2}
      )

    assert_raise ArgumentError, fn -> Date.from_iso8601!("x") end

    assert {[call, exception], :event_limit, _stats} = collect(tracer)
    assert %{type: :call, mfa: {Date, :from_iso8601!, 1}} = call
    assert %{type: :exception, mfa: {Date, :from_iso8601!, 1}, value: {:error, _}} = exception
  end

  test "a match spec guard filters calls" do
    match_spec = [{[:"$1", :_], [{:==, :"$1", "keep"}], []}]
    {:ok, tracer} = start(spec(match_spec: match_spec), %{@limits | max_events: 1})

    String.jaro_distance("drop", "x")
    String.jaro_distance("keep", "x")

    assert {[%{type: :call, args: ["keep", "x"]}], :event_limit, _stats} = collect(tracer)
  end

  test "a match spec message action lands in the event" do
    match_spec = [{[:"$1", :_], [], [{:message, :"$1"}]}]
    {:ok, tracer} = start(spec(match_spec: match_spec), %{@limits | max_events: 1})

    String.jaro_distance("voyager", "x")

    assert {[%{type: :call, message: "voyager"}], :event_limit, _stats} = collect(tracer)
  end

  test "rejects match specs it cannot or should not install" do
    assert {:error, {:refused_action, :silent}} =
             start(spec(match_spec: [{:_, [], [{:silent, true}]}]), @limits)

    assert {:error, {:invalid_match_spec, [_ | _]}} =
             start(spec(match_spec: [{:_, [{:no_such_guard, :"$1"}], []}]), @limits)

    assert {:error, {:invalid_match_spec, [_ | _]}} =
             start(spec(match_spec: [{:_, [], [{:no_such_action, 1}]}]), @limits)

    assert {:error, {:invalid, :match_spec}} =
             start(spec(match_spec: List.duplicate({:_, [], []}, 11)), @limits)
  end

  test "refuses actions nested deep in a body or guard" do
    for {match_spec, action} <- [
          {[{:_, [], [{:message, {{:ok, {:display, :x}}}}]}], :display},
          {[{:_, [{:is_list, {:current_stacktrace}}], []}], :current_stacktrace},
          {[{:_, [], [{:set_tcw, 1}]}], :set_tcw},
          {[{:_, [], [{:message, false}, {:exception_trace}]}], :exception_trace},
          {[{:_, [], [{:return_trace}]}], :return_trace}
        ] do
      assert {:error, {:refused_action, ^action}} = start(spec(match_spec: match_spec), @limits)
    end
  end

  test "refuses any message action when return trace is on" do
    for body <- [[{:message, false}], [{:message, {:const, false}}]] do
      assert {:error, {:refused_action, :message}} =
               start(spec(match_spec: [{:_, [], body}], return_trace: true), @limits)
    end
  end

  test "rejects each malformed spec field" do
    for {overrides, field} <- [
          {[module: :String], :module},
          {[module: :_], :module},
          {[function: :jaro_distance], :function},
          {[arity: 256], :arity},
          {[arity: -1], :arity},
          {[arity: :any], :arity},
          {[function: :_, arity: 2], :arity},
          {[processes: []], :processes},
          {[processes: :some], :processes},
          {[processes: [:not_a_pid]], :processes},
          {[processes: List.duplicate(self(), 101)], :processes},
          {[capture: :both], :capture},
          {[scope: true], :scope},
          {[return_trace: :yes], :return_trace},
          {[match_spec: []], :match_spec},
          {[match_spec: :nope], :match_spec},
          {[match_spec: [:not_a_clause]], :match_spec}
        ] do
      assert {:error, {:invalid, ^field}} = start(spec(overrides), @limits),
             "expected {:invalid, #{inspect(field)}} for #{inspect(overrides)}"
    end

    assert {:error, {:invalid, :scope}} = start(Map.delete(spec(), :scope), @limits)
  end

  test "rejects each malformed limit" do
    for {limits, field} <- [
          {%{budget: 50}, :limits},
          {%{@limits | max_events: 0}, :max_events},
          {%{@limits | max_rate: -1}, :max_rate},
          {%{@limits | max_time_ms: "5000"}, :max_time_ms},
          {%{@limits | max_time_ms: 3_600_001}, :max_time_ms},
          {%{@limits | budget: -1}, :budget},
          {%{@limits | budget: 100_001}, :budget},
          {Map.delete(@limits, :budget), :budget}
        ] do
      assert {:error, {:invalid, ^field}} = start(spec(), limits),
             "expected {:invalid, #{inspect(field)}} for #{inspect(limits)}"
    end
  end

  test "rejects remote and dead pids" do
    assert {:error, {:invalid, :processes}} = start(spec(processes: [remote_pid()]), @limits)

    dead = start_supervised!({Task, fn -> :ok end})
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    assert {:error, {:noproc, ^dead}} = start(spec(processes: [self(), dead]), @limits)
    assert @agent_module.trace_sessions() == 0
  end

  test "rejects specs it cannot or should not trace" do
    assert {:error, {:refused, :erlang}} =
             start(spec(module: "erlang", function: "self", arity: 0, processes: :all), @limits)

    assert {:error, :unknown_function} =
             start(spec(module: "Elixir.NoSuchModule#{System.unique_integer()}"), @limits)

    assert {:error, {:not_loaded, VoyagerAgentTraceTest.NotLoaded}} =
             start(spec(module: Atom.to_string(VoyagerAgentTraceTest.NotLoaded)), @limits)

    assert {:error, :no_function_matched} = start(spec(arity: 9), @limits)
    assert {:error, {:invalid, :module}} = start(spec(module: "_"), @limits)
  end

  test "hot modules are refused on process sets but allowed on a pid list" do
    lists = [module: "lists", function: "reverse", arity: 1]

    for set <- [:all, :existing, :new] do
      assert {:error, {:refused, :lists}} = start(spec(lists ++ [processes: set]), @limits)
    end

    assert {:error, {:refused, :prim_file}} =
             start(spec(module: "prim_file", function: :_, arity: :_, processes: :all), @limits)

    assert {:ok, _tracer} = start(spec(lists), @limits)
  end

  test "the agent and trace modules are refused even on a pid list" do
    agent = [module: Atom.to_string(@agent_module), function: :_, arity: :_]

    assert {:error, {:refused, @agent_module}} = start(spec(agent), @limits)

    assert {:error, {:refused, :trace}} =
             start(spec(module: "trace", function: :_, arity: :_), @limits)
  end

  test "caps a node at five sessions" do
    assert eventually(fn -> @agent_module.trace_sessions() == 0 end)

    for _ <- 1..5, do: assert({:ok, _tracer} = start(spec(), @limits))

    assert @agent_module.trace_sessions() == 5
    assert {:error, :too_many_sessions} = start(spec(), @limits)
    assert @agent_module.trace_sessions() == 5
  end

  test "allows a single all-processes session" do
    all = spec(module: "Elixir.Date", function: "leap_year?", arity: 1, processes: :all)

    assert {:ok, _tracer} = start(all, @limits)
    assert {:error, :all_processes_busy} = start(all, @limits)
    assert {:error, :all_processes_busy} = start(spec(@leap_year ++ [processes: :new]), @limits)
    assert {:ok, _tracer} = start(spec(), @limits)
    assert @agent_module.trace_sessions() == 2
  end

  test "trace_stop ends the trace and removes the session" do
    {:ok, tracer} = start(spec(), @limits)
    ref = Process.monitor(tracer)

    assert :ok = @agent_module.trace_stop(tracer)

    assert_receive {:DOWN, ^ref, :process, ^tracer, _reason}
    assert {[], :stopped, _stats} = collect(tracer)
    assert voyager_sessions(:trace.session_info(:all)) == []
    assert voyager_sessions(:trace.session_info(self())) == []
    assert @agent_module.trace_sessions() == 0
    assert {:error, :not_found} = @agent_module.trace_stop(tracer)
  end

  test "a killed tracer leaves no session behind" do
    {:ok, tracer} = start(spec(), @limits)
    ref = Process.monitor(tracer)

    Process.exit(tracer, :kill)

    assert_receive {:DOWN, ^ref, :process, ^tracer, :killed}
    assert eventually(fn -> voyager_sessions(:trace.session_info(:all)) == [] end)
    assert voyager_sessions(:trace.session_info(self())) == []
  end

  test "trace_stop leaves processes that are not tracers alone" do
    other = start_supervised!({Agent, fn -> nil end})

    assert {:error, :not_found} = @agent_module.trace_stop(other)
    assert {:error, :not_found} = @agent_module.trace_stop(self())
    assert Agent.get(other, & &1) == nil
  end

  test "stops when its mailbox backs up" do
    {:ok, tracer} = start(spec(), %{max_time_ms: 5_000, budget: 10})

    :erlang.suspend_process(tracer)
    for _ <- 1..5_100, do: String.jaro_distance("a", "b")
    :erlang.resume_process(tracer)

    assert {_events, :mailbox_limit, %{dropped: dropped}} = collect(tracer)
    assert dropped > 5_000
  end

  test "survives a full-budget flood of large arguments" do
    big = Enum.to_list(1..100_000)

    {:ok, tracer} =
      start(spec(module: "Elixir.Enum", function: "sum", arity: 1), %{
        max_events: 60,
        budget: 100_000
      })

    for _ <- 1..60, do: Enum.sum(big)

    assert {_events, :event_limit, %{events: 60}} = collect(tracer)
  end

  test "trace_stop kills a tracer that does not stop in time" do
    {:ok, tracer} = start(spec(), @limits)
    ref = Process.monitor(tracer)
    :erlang.suspend_process(tracer)

    assert {:error, :timeout} = @agent_module.trace_stop(tracer)
    assert_receive {:DOWN, ^ref, :process, ^tracer, :killed}
  end

  defp spec(overrides \\ []) do
    Enum.into(overrides, %{
      module: "Elixir.String",
      function: "jaro_distance",
      arity: 2,
      processes: [self()],
      capture: :args,
      scope: :global,
      return_trace: false,
      match_spec: :undefined
    })
  end

  defp start(spec, limits, collector \\ self()) do
    case @agent_module.trace_start(collector, spec, limits) do
      {:ok, tracer} = ok ->
        on_exit(fn -> @agent_module.trace_stop(tracer) end)
        ok

      error ->
        error
    end
  end

  defp voyager_sessions(sessions) do
    Enum.filter(sessions, &match?({name, _} when name in [:voyager, :voyager_all], &1))
  end

  # A killed tracer's session is freed with its heap, which can land just after DOWN.
  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        :erlang.yield()
        eventually(check, deadline)
    end
  end

  defp remote_pid do
    node = "voyager_remote@nohost"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 0::96>>)
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
