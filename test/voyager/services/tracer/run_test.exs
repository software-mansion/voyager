defmodule Voyager.Services.Tracer.RunTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.CallPairing
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Run
  alias Voyager.Services.Tracer.Session

  @mfa {Enum, :map, 2}

  defp session(opts \\ []) do
    %Session{
      id: -1,
      origin: :ui,
      created_at: DateTime.utc_now(),
      config: %Config{return_trace: Keyword.get(opts, :return_trace, false)},
      traces: Keyword.get(opts, :traces, 0),
      dropped: Keyword.get(opts, :dropped, 0)
    }
  end

  defp event(type, at), do: %{type: type, at: at, pid: self(), mfa: @mfa}

  defp events(count), do: for(at <- 1..count//1, do: event(:call, at))

  describe "absorb/5" do
    test "counts the events and logs the agent's drops before them" do
      session = session()
      run = Run.new(session, :ui)

      assert {[%{kind: :dropped, count: 2} | traces], session, run} =
               Run.absorb(run, session, events(3), 2, false)

      assert [%{kind: :trace}, %{kind: :trace}, %{kind: :trace}] = traces
      assert session.traces == 3
      assert session.dropped == 2
      assert run.dropped_logged == 2
      assert run.shed == 0
    end

    test "logs only drops that are new since the last batch" do
      session = session()
      run = Run.new(session, :ui)

      {[%{count: 2}], session, run} = Run.absorb(run, session, [], 2, false)
      assert {[%{count: 3}], session, _run} = Run.absorb(run, session, [], 5, false)
      assert session.dropped == 5
    end

    test "sheds the whole batch while shedding, without logging drops" do
      session = session()
      run = Run.new(session, :ui)

      assert {[], session, run} = Run.absorb(run, session, events(4), 1, true)

      assert session.traces == 0
      assert session.dropped == 5
      assert run.shed == 4
      assert run.dropped_logged == 0
    end

    test "logs the shed drops once shedding ends" do
      session = session()
      run = Run.new(session, :ui)

      {[], session, run} = Run.absorb(run, session, events(4), 0, true)
      {[], session, run} = Run.absorb(run, session, events(2), 0, true)

      assert {[%{kind: :dropped, count: 6}, %{kind: :trace}], session, run} =
               Run.absorb(run, session, events(1), 0, false)

      assert session.dropped == 6
      assert run.dropped_logged == 6
    end

    test "builds on the drops of earlier runs" do
      session = session(traces: 10, dropped: 7)
      run = Run.new(session, :ui)

      assert {[%{kind: :trace}], session, _run} = Run.absorb(run, session, events(1), 0, false)
      assert session.dropped == 7
      assert session.traces == 11
    end

    test "resets the pairing when drops grow" do
      session = session(return_trace: true)
      run = Run.new(session, :ui)

      {_entries, session, run} = Run.absorb(run, session, [event(:call, 1)], 0, false)
      assert run.pairing.count == 1

      assert {[%{kind: :dropped}, ret], _session, run} =
               Run.absorb(run, session, [event(:return, 9)], 1, false)

      refute Map.has_key?(ret, :duration_us)
      assert run.pairing == %CallPairing{}
    end

    test "keeps the pairing when nothing was dropped" do
      session = session(return_trace: true)
      run = Run.new(session, :ui)

      {_entries, session, run} = Run.absorb(run, session, [event(:call, 1)], 0, false)
      assert {[ret], _session, _run} = Run.absorb(run, session, [event(:return, 9)], 0, false)
      assert ret.duration_us == 8
    end

    test "leaves events and pairing alone without return_trace" do
      session = session(return_trace: false)
      run = Run.new(session, :ui)
      batch = [event(:call, 1), event(:return, 4)]

      assert {entries, _session, run} = Run.absorb(run, session, batch, 0, false)
      assert entries == Enum.map(batch, &Entry.trace/1)
      assert run.pairing == %CallPairing{}
    end
  end
end
