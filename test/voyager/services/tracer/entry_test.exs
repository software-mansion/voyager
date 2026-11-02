defmodule Voyager.Services.Tracer.EntryTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry

  test "builds control entries with their origin and timestamp" do
    config = %Config{}

    assert %{kind: :configured, origin: :ui, node: :a@host, config: ^config, at: at} =
             Entry.configured(:ui, :a@host, config)

    assert is_integer(at)
    assert %{kind: :started, origin: :mcp} = Entry.started(:mcp)

    assert %{kind: :stopped, origin: nil, reason: :stopped, traces: 2, dropped: 1} =
             Entry.stopped(nil, :stopped, 2, 1)
  end

  test "adds a dropped entry only when something was dropped" do
    assert Entry.dropped(0) == []
    assert [%{kind: :dropped, origin: nil, count: 3}] = Entry.dropped(3)
  end

  test "marks an event as a trace entry" do
    assert Entry.trace(%{type: :call}) == %{type: :call, kind: :trace}
  end
end
