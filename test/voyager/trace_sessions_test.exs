defmodule Voyager.TraceSessionsTest do
  use Voyager.DataCase, async: true

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Queries.TraceEntries, as: TraceEntryQueries
  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceEvent
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Search
  alias Voyager.Services.Tracer.Session

  test "interrupt_running/0 stops running sessions" do
    %{id: running} = session!(:running)
    %{id: idle} = session!(:idle)

    assert :ok = TraceSessionActions.interrupt_running()

    assert %{status: :stopped, stop_reason: :interrupted, stopped_at: %DateTime{}} =
             TraceSessionQueries.get(running)

    assert %{status: :idle} = TraceSessionQueries.get(idle)
  end

  test "bytes_except/1 sums the other sessions' bytes, 0 when there are none" do
    assert 0 == TraceSessionQueries.bytes_except(0)

    %{id: id} = session!(:stopped, 40)
    session!(:stopped, 60)

    assert 100 == TraceSessionQueries.bytes_except(0)
    assert 60 == TraceSessionQueries.bytes_except(id)
  end

  test "deleting a session deletes its entries" do
    %{id: id} = session!(:stopped)
    TraceEntryActions.insert_all(id, [trace(0, %{})])

    assert {:ok, _session} = TraceSessionActions.delete(id)
    assert TraceEntryQueries.page(id, limit: 10) == []
    assert {:error, :not_found} = TraceSessionActions.delete(id)
  end

  test "round-trips session entries" do
    %{id: id} = session!(:stopped)
    config = %Config{module: "Elixir.Date", pids: ["<0.1.0>"], capture: :args, max_events: 5}

    entries = [
      %{
        seq: 0,
        kind: :configured,
        at: 1,
        origin: :mcp,
        node: :app@host,
        config: config,
        previous: nil
      },
      %{seq: 1, kind: :started, at: 2, origin: :ui},
      %{seq: 2, kind: :dropped, at: 3, origin: nil, count: 4},
      %{
        seq: 3,
        kind: :stopped,
        at: 4,
        origin: nil,
        reason: {:tracer_down, :killed},
        traces: 0,
        dropped: 4
      }
    ]

    TraceEntryActions.insert_all(id, entries)

    assert TraceEntryQueries.page(id, since: 0, order: :asc, limit: 10) == entries

    assert [%{seq: 3}, %{seq: 1}, %{seq: 0}] = TraceEntryQueries.controls(id)
    assert TraceEntryQueries.next_seq(id) == 4
  end

  test "page/2 reads forward from since or back from before" do
    %{id: id} = session!(:stopped)
    TraceEntryActions.insert_all(id, Enum.map(0..4, &trace(&1, %{})))

    assert [1, 2] == seqs(TraceEntryQueries.page(id, since: 1, order: :asc, limit: 2))
    assert [2, 3] == seqs(TraceEntryQueries.page(id, since: 2, order: :asc, before: 4, limit: 10))
    assert [4, 3] == seqs(TraceEntryQueries.page(id, limit: 2))
    assert [2, 1] == seqs(TraceEntryQueries.page(id, before: 3, limit: 2))
    assert TraceEntryQueries.next_seq(session!(:idle).id) == 0
  end

  test "reads both tables as one log ordered by seq" do
    %{id: id} = session!(:stopped)

    TraceEntryActions.insert_all(id, [
      %{seq: 0, kind: :started, at: 1, origin: :ui},
      trace(1, %{}),
      trace(2, %{}),
      %{seq: 3, kind: :dropped, at: 2, origin: nil, count: 1},
      trace(4, %{}),
      %{seq: 5, kind: :stopped, at: 3, origin: :ui, reason: :stopped, traces: 3, dropped: 1}
    ])

    assert [0, 1, 2, 3] == seqs(TraceEntryQueries.page(id, since: 0, order: :asc, limit: 4))
    assert [4, 3, 2] == seqs(TraceEntryQueries.page(id, before: 5, limit: 3))
    assert [5, 0] == seqs(TraceEntryQueries.controls(id))
    assert TraceEntryQueries.next_seq(id) == 6

    assert {:ok, _session} = TraceSessionActions.delete(id)
    assert TraceEntryQueries.page(id, limit: 10) == []
  end

  test "round-trips trace entries, a nil return value included" do
    %{id: id} = session!(:running)

    entries = [
      trace(0, %{args: [self(), "bin", make_ref()], truncated: true}),
      trace(1, %{type: :return, value: nil, truncated: false, duration_us: 12}),
      trace(2, %{type: :exception, value: {:error, :badarg}, truncated: false}),
      trace(3, %{process: {:proc_lib, :init_p, 5}})
    ]

    TraceEntryActions.insert_all(id, entries)

    assert TraceEntryQueries.page(id, since: 0, order: :asc, limit: 10) == entries
  end

  test "insert_all/2 stores the inspected event as search text and counts its bytes" do
    %{id: id} = session!(:running)
    pid = self()
    pid_string = Voyager.Pid.format(pid, :local)
    call = trace(0, %{args: [pid, "bin"], truncated: true})

    bytes = TraceEntryActions.insert_all(id, [call])

    assert %{search_text: text} = Repo.get_by!(TraceEvent, session_id: id)

    assert text ==
             ~s(#PID#{pid_string} :my_server Date.leap_year?/1 [#PID#{pid_string}, "bin"])

    terms = [pid, :my_server, call.args] |> Enum.map(&:erlang.external_size/1) |> Enum.sum()

    assert bytes ==
             64 + terms + byte_size(text) + byte_size("Elixir.Date") + byte_size("leap_year?")
  end

  test "insert_all/2 counts a configured entry's config bytes" do
    %{id: id} = session!(:idle)
    pids = for n <- 1..100, do: "<0.#{n}.0>"
    config = %Voyager.Services.Tracer.Config{module: "Elixir.Date", pids: pids}
    entry = %{seq: 0, kind: :configured, at: 1, origin: :ui, node: node(), config: config}

    assert TraceEntryActions.insert_all(id, [entry]) > 100 * byte_size("<0.1.0>")
  end

  test "compresses large terms and counts the compressed bytes" do
    %{id: id} = session!(:running)
    args = [List.duplicate(%{state: :running, name: "worker"}, 200)]

    bytes = TraceEntryActions.insert_all(id, [trace(0, %{args: args, truncated: false})])

    assert [%{args: ^args}] = TraceEntryQueries.page(id, limit: 1)
    assert %{args: stored} = Repo.get_by!(TraceEvent, session_id: id)
    assert byte_size(stored) < :erlang.external_size(args) / 10
    assert bytes < :erlang.external_size(args)
  end

  test "from_row/4 reads a never started session" do
    assert %Session{id: 1, save: true, node: nil, run_started_at: nil, run_traces_before: 0} =
             Session.from_row(row(), [], 0, 0)
  end

  test "from_row/4 takes the newest config and the last run" do
    first = %Config{module: "Elixir.Date"}
    second = %Config{module: "Elixir.Time"}

    log = [
      %{seq: 7, kind: :stopped, at: 7, traces: 9},
      %{seq: 6, kind: :started, at: 6},
      %{seq: 5, kind: :configured, at: 5, node: :b@host, config: second},
      %{seq: 4, kind: :stopped, at: 4, traces: 3},
      %{seq: 3, kind: :started, at: 3},
      %{seq: 2, kind: :stopped, at: 2, traces: 2},
      %{seq: 1, kind: :started, at: 1},
      %{seq: 0, kind: :configured, at: 0, node: :a@host, config: first}
    ]

    assert %Session{node: :b@host, config: ^second, run_traces_before: 5, run_started_at: at} =
             Session.from_row(%{row() | traces: 14}, log, 0, 0)

    assert at == DateTime.from_unix!(6, :microsecond)
  end

  test "from_row/4 counts an earlier run interrupted without a stopped entry" do
    log = [
      %{seq: 3, kind: :stopped, at: 4, traces: 3},
      %{seq: 2, kind: :started, at: 3},
      %{seq: 1, kind: :started, at: 1},
      %{seq: 0, kind: :configured, at: 0, node: :a@host, config: %Config{}}
    ]

    assert %Session{run_traces_before: 5} = Session.from_row(%{row() | traces: 8}, log, 0, 0)
  end

  test "from_row/4 counts the runs before one interrupted without a stopped entry" do
    log = [
      %{seq: 2, kind: :started, at: 3},
      %{seq: 1, kind: :stopped, at: 2, traces: 4},
      %{seq: 0, kind: :started, at: 1}
    ]

    assert %Session{run_traces_before: 4, run_started_at: at} = Session.from_row(row(), log, 0, 0)
    assert at == DateTime.from_unix!(3, :microsecond)
  end

  test "search/3 matches Search.text/1, one session and trace rows only" do
    %{id: id} = session!(:stopped)
    %{id: other} = session!(:stopped)
    needle = trace(1, %{args: ["needle"]})

    TraceEntryActions.insert_all(id, [
      %{seq: 0, kind: :started, at: 1, origin: :ui},
      needle,
      trace(2, %{args: ["other"]})
    ])

    TraceEntryActions.insert_all(other, [trace(0, %{args: ["needle"]})])

    assert %{entries: [%{seq: 1}], total: 1} =
             TraceEntryQueries.search(id, Search.text(needle), limit: 10)

    assert %{entries: [], total: 0} = TraceEntryQueries.search(id, "started", limit: 10)
  end

  defp seqs(entries), do: Enum.map(entries, & &1.seq)

  defp row do
    %TraceSession{id: 1, origin: :ui, status: :stopped, inserted_at: ~N[2026-01-01 00:00:00]}
  end

  defp session!(status, bytes \\ 0) do
    Repo.insert!(%TraceSession{origin: :ui, status: status, bytes: bytes})
  end

  defp trace(seq, overrides) do
    Map.merge(
      %{
        seq: seq,
        kind: :trace,
        type: :call,
        pid: self(),
        process: :my_server,
        mfa: {Date, :leap_year?, 1},
        at: System.os_time(:microsecond)
      },
      overrides
    )
  end
end
