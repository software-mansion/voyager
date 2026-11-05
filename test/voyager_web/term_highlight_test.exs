defmodule VoyagerWeb.TermHighlightTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.TermHighlight

  test "kinds Elixir tokens" do
    assert TermHighlight.parts(~s({:ok, "a", 1.5, nil, Date, #PID<0.1.0>}), :elixir) == [
             {:punctuation, false, "{"},
             {:atom, false, ":ok"},
             {:punctuation, false, ", "},
             {:string, false, ~s("a")},
             {:punctuation, false, ", "},
             {:number, false, "1.5"},
             {:punctuation, false, ", "},
             {:special, false, "nil"},
             {:punctuation, false, ", "},
             {:atom, false, "Date"},
             {:punctuation, false, ", "},
             {:other, false, "#PID<0.1.0>"},
             {:punctuation, false, "}"}
           ]
  end

  test "kinds bare and quoted atoms only under Erlang syntax" do
    assert TermHighlight.parts("{ok, 'A b'}", :erlang) == [
             {:punctuation, false, "{"},
             {:atom, false, "ok"},
             {:punctuation, false, ", "},
             {:atom, false, "'A b'"},
             {:punctuation, false, "}"}
           ]

    refute {:atom, false, "ok"} in TermHighlight.parts("{ok, 'A b'}", :elixir)
  end

  test "splits a mark crossing a token edge so each part keeps one kind" do
    assert TermHighlight.parts("[:ok, 1]", :elixir, "k, 1") == [
             {:punctuation, false, "["},
             {:atom, false, ":o"},
             {:atom, true, "k"},
             {:punctuation, true, ", "},
             {:number, true, "1"},
             {:punctuation, false, "]"}
           ]
  end

  test "marks case-insensitively" do
    assert TermHighlight.parts(~s("Hello"), :elixir, "hello") == [
             {:string, false, ~s(")},
             {:string, true, "Hello"},
             {:string, false, ~s(")}
           ]
  end

  test "marks nothing without a query" do
    parts = TermHighlight.parts(~s({:ok, "ok"}), :elixir)

    refute Enum.any?(parts, fn {_kind, marked?, _text} -> marked? end)
    assert Enum.map_join(parts, &elem(&1, 2)) == ~s({:ok, "ok"})
  end

  test "keeps the text whole and unkinded without a syntax" do
    assert TermHighlight.parts("Date.leap_year?/1", nil, "year") == [
             {nil, false, "Date.leap_"},
             {nil, true, "year"},
             {nil, false, "?/1"}
           ]
  end
end
