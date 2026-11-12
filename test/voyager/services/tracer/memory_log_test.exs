defmodule Voyager.Services.Tracer.MemoryLogTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.MemoryLog

  defp entries(kinds), do: Enum.map(kinds, &%{kind: &1, at: 0})

  defp log_of(kinds) do
    {_entries, log} = MemoryLog.append(%MemoryLog{}, entries(kinds), 0)
    log
  end

  defp seqs(%{entries: entries}), do: Enum.map(entries, & &1.seq)

  describe "append/3" do
    test "numbers entries from seq" do
      {numbered, _log} = MemoryLog.append(%MemoryLog{}, entries([:started, :trace, :trace]), 7)
      assert Enum.map(numbered, & &1.seq) == [7, 8, 9]
    end

    test "keeps controls and traces apart, newest first" do
      log = log_of([:configured, :trace, :dropped, :started, :trace])

      assert Enum.map(log.controls, & &1.seq) == [3, 0]
      assert Enum.map(log.traces, & &1.seq) == [4, 2, 1]
    end

    test "caps traces at the newest 500 and never evicts controls" do
      log = log_of([:configured | List.duplicate(:trace, 600)] ++ [:stopped])

      assert length(log.traces) == 500
      assert hd(log.traces).seq == 600
      assert List.last(log.traces).seq == 101
      assert Enum.map(log.controls, & &1.seq) == [601, 0]
    end

    test "caps dropped entries with the traces" do
      log = log_of(List.duplicate(:dropped, 600))
      assert length(log.traces) == 500
    end

    test "summarizes the traces it evicts too" do
      call = %{
        kind: :trace,
        type: :call,
        at: 0,
        pid: self(),
        process: nil,
        mfa: {Date, :leap_year?, 1}
      }

      {_entries, log} = MemoryLog.append(%MemoryLog{}, List.duplicate(call, 600), 0)

      assert length(log.traces) == 500
      assert log.summary.calls == 600
    end

    test "continues numbering across calls" do
      {first, log} = MemoryLog.append(%MemoryLog{}, entries([:trace, :trace]), 0)
      {second, log} = MemoryLog.append(log, entries([:trace]), length(first))

      assert Enum.map(log.traces, & &1.seq) == [2, 1, 0]
      assert Enum.map(second, & &1.seq) == [2]
    end
  end

  describe "page/3" do
    test "returns the range in the requested order" do
      log = log_of([:configured, :started | List.duplicate(:trace, 4)])

      asc = MemoryLog.page(log, 6, since: 1, before: 5, order: :asc, limit: 10)
      desc = MemoryLog.page(log, 6, since: 1, before: 5, order: :desc, limit: 10)

      assert seqs(asc) == [1, 2, 3, 4]
      assert seqs(desc) == [4, 3, 2, 1]
    end

    test "is not truncated when nothing was evicted" do
      log = log_of([:configured | List.duplicate(:trace, 5)])
      assert %{truncated?: false} = MemoryLog.page(log, 6, order: :asc, limit: 100)
    end

    test "is truncated when a short page's range has evicted entries" do
      log = log_of([:configured | List.duplicate(:trace, 600)])
      page = MemoryLog.page(log, 601, order: :asc, limit: 1_000)

      assert length(page.entries) == 501
      assert page.truncated?
    end

    test "a full ascending page covers the range up to its last entry" do
      log = log_of([:configured | List.duplicate(:trace, 600)])

      assert %{truncated?: true} = MemoryLog.page(log, 601, order: :asc, limit: 2)
      assert %{truncated?: false} = MemoryLog.page(log, 601, since: 101, order: :asc, limit: 100)
    end

    test "a full descending page covers the range from its last entry" do
      log = log_of([:configured | List.duplicate(:trace, 600)])

      assert %{truncated?: false} = MemoryLog.page(log, 601, order: :desc, limit: 500)
      assert %{truncated?: true} = MemoryLog.page(log, 601, order: :desc, limit: 501)
    end

    test "clamps before to next_seq" do
      log = log_of([:configured, :trace, :trace])
      page = MemoryLog.page(log, 3, before: 100, order: :asc, limit: 10)

      assert seqs(page) == [0, 1, 2]
      refute page.truncated?
    end

    test "an empty range is not truncated" do
      log = log_of([:configured, :trace])

      assert %{entries: [], truncated?: false} =
               MemoryLog.page(log, 2, since: 2, order: :desc, limit: 10)

      assert %{entries: [], truncated?: false} =
               MemoryLog.page(%MemoryLog{}, 0, order: :asc, limit: 10)
    end
  end
end
