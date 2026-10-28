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

  test "interrupt_running/0 stops running sessions" do
    %{id: running} = session!(:running)
    %{id: idle} = session!(:idle)

    assert :ok = TraceSessionActions.interrupt_running()

    assert %{status: :stopped, stop_reason: :interrupted, stopped_at: %DateTime{}} =
             TraceSessionQueries.get(running)

    assert %{status: :idle} = TraceSessionQueries.get(idle)
  end

  test "prune/2 deletes the oldest saved sessions over the limit, never the kept one" do
    session!(:stopped, 40)
    %{id: empty} = session!(:stopped)
    session!(:stopped, 40)
    %{id: newer} = session!(:stopped, 30)
    %{id: kept} = session!(:running, 50)

    assert :ok = TraceSessionActions.prune(100, kept)

    assert Enum.map(TraceSessionQueries.all(), & &1.id) == [kept, newer, empty]
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
      %{seq: 0, kind: :configured, at: 1, origin: :mcp, node: :app@host, config: config},
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
    assert [%{seq: 2}] = TraceEntryQueries.traces(id, 10)
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
    assert [4, 3] == seqs(TraceEntryQueries.traces(id, 2))
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

  defp seqs(entries), do: Enum.map(entries, & &1.seq)

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
