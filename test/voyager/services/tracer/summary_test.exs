defmodule Voyager.Services.Tracer.SummaryTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Summary

  defp call(pid, mfa \\ {Date, :leap_year?, 1}, process \\ :worker),
    do: %{kind: :trace, type: :call, pid: pid, mfa: mfa, process: process}

  defp timed(type, duration_us), do: %{kind: :trace, type: type, duration_us: duration_us}

  test "counts calls per function and per process, with the process' latest name" do
    a = :c.pid(0, 1, 0)
    b = :c.pid(0, 2, 0)

    summary =
      Summary.add(%Summary{}, [
        call(a),
        call(a, {Date, :utc_today, 0}, :renamed),
        call(b),
        %{kind: :started}
      ])

    assert summary.calls == 3
    assert summary.functions == %{{Date, :leap_year?, 1} => 2, {Date, :utc_today, 0} => 1}
    assert summary.processes == %{a => {:renamed, 2}, b => {:worker, 1}}
  end

  test "counts returns and exceptions and keeps the slowest timed ones" do
    entries =
      [timed(:exception, 900), %{kind: :trace, type: :return}] ++
        Enum.map(1..6, &timed(:return, &1 * 100))

    summary = Summary.add(%Summary{}, entries)

    assert summary.returns == 7
    assert summary.exceptions == 1
    assert Enum.map(summary.slowest, & &1.duration_us) == [900, 600, 500, 400, 300]
  end

  test "keeps the busiest half of a full map and still takes new processes" do
    max = Summary.max_keys()
    summary = Summary.add(%Summary{}, [call(:busy) | Enum.map(1..(max - 1), &call/1)])
    summary = Summary.add(summary, [call(:busy), call(:late), call(:late)])

    assert summary.calls == max + 3
    assert map_size(summary.processes) == div(max, 2) + 1
    assert summary.processes[:busy] == {:worker, 2}
    assert summary.processes[:late] == {:worker, 2}
  end
end
