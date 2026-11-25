defmodule Voyager.MCP.Tools.TraceWatchTest do
  # async: false because the tool drives the global `Tracer` and `Voyager.NodeSession`.
  use Voyager.TraceToolCase, async: false

  alias Anubis.Server.Context
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.TraceWatch

  test "waits for the running session to end and returns its report" do
    configure(%{max_events: 4})
    {:ok, _session} = Tracer.start(:ui)
    watch = watch()

    trace_calls(2)

    assert %{
             "status" => "stopped",
             "stop_reason" => "event_limit",
             "total_events" => 4,
             "summary" => %{"calls" => 2}
           } = json!(Task.await(watch))
  end

  test "starts a session that never ran" do
    configure(%{max_events: 2})
    watch = watch()
    assert_receive {:session_entries, %{status: :running}, [%{kind: :started, origin: :mcp}]}

    Date.leap_year?(~D[2024-01-01])

    assert %{"status" => "stopped", "stop_reason" => "event_limit"} = json!(Task.await(watch))
  end

  test "joins the session when another watch starts it first" do
    configure(%{max_events: 2})
    tracer = Process.whereis(Tracer)
    :sys.suspend(tracer)
    watches = for _watch <- 1..2, do: Task.async(fn -> TraceWatch.execute(%{}, %Frame{}) end)

    _both_read_it_idle =
      Stream.repeatedly(fn -> Process.info(tracer, :message_queue_len) end)
      |> Enum.find(fn {:message_queue_len, len} -> len >= 2 end)

    :sys.resume(tracer)
    assert_receive {:session_entries, %{status: :running}, [%{kind: :started}]}
    trace_calls(1)

    for watch <- watches do
      assert %{"status" => "stopped", "stop_reason" => "event_limit"} = json!(Task.await(watch))
    end
  end

  test "reports progress while it waits" do
    configure(%{max_events: 4})
    {:ok, _session} = Tracer.start(:ui)

    frame = %Frame{
      context: %Context{session_pid: self(), request_meta: %{"progressToken" => "t"}}
    }

    watch = Task.async(fn -> TraceWatch.execute(%{}, frame) end)

    assert_receive {:send_notification, "notifications/progress",
                    %{"progressToken" => "t", "progress" => 0}}

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:send_notification, "notifications/progress",
                    %{"progress" => 2, "message" => "2 events" <> _}},
                   2_000

    Tracer.stop(:ui)
    assert %{"status" => "stopped"} = json!(Task.await(watch))
  end

  test "leaves the session running when the watch is cancelled" do
    configure()
    {:ok, _session} = Tracer.start(:ui)
    %Task{pid: pid} = watch()
    Process.unlink(pid)
    ref = Process.monitor(pid)

    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert %{status: :running} = Tracer.active()
  end

  test "fails once the session is gone, after a Tracer restart" do
    configure()
    {:ok, _session} = Tracer.start(:ui)
    %Task{pid: pid} = watch = watch()

    _awaiting =
      Stream.repeatedly(fn -> Process.info(pid, :current_function) end)
      |> Enum.find(&(is_nil(&1) or match?({_key, {TraceWatch, :await, 3}}, &1)))

    Process.exit(Process.whereis(Tracer), :kill)

    assert error!(Task.await(watch)) =~ "closed"
  end

  test "keeps waiting through updates queued before the watched run" do
    %{id: id} = configure(%{max_events: 2})
    {:ok, running} = Tracer.start(:ui)
    %Task{pid: pid} = watch = watch()

    send(pid, {:session_updated, %{running | status: :stopped, seq: 0}})
    send(pid, {:session_updated, %{running | status: :idle}})
    send(pid, {:session_updated, nil})
    refute Task.yield(watch, 100)

    trace_calls(1)

    assert %{"session_id" => ^id, "status" => "stopped", "stop_reason" => "event_limit"} =
             json!(Task.await(watch))
  end

  test "returns a stopped session's report at once" do
    configure(%{max_events: 2})
    {:ok, _session} = Tracer.start(:ui)
    trace_calls(1)

    assert %{"status" => "stopped"} = json!(TraceWatch.execute(%{}, %Frame{}))
  end

  test "refuses without a session or a connection to start it on" do
    assert error!(TraceWatch.execute(%{}, %Frame{})) =~ "no tracing session"

    configure()
    Fakes.put_session(nil)
    assert error!(TraceWatch.execute(%{}, %Frame{})) =~ "connect"
  end

  # Returns once the watch is subscribed, so nothing the test does next is missed.
  defp watch do
    task = Task.async(fn -> TraceWatch.execute(%{}, %Frame{}) end)

    _subscribed =
      Stream.repeatedly(fn -> Registry.lookup(Voyager.PubSub, Tracer.session_topic()) end)
      |> Enum.find(&Enum.any?(&1, fn {pid, _value} -> pid == task.pid end))

    task
  end
end
