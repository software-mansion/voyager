defmodule Voyager.FuzzySearchTest do
  use ExUnit.Case, async: true

  alias Voyager.FuzzySearch

  describe "rank/2" do
    test "ranks exact, prefix, substring, then subsequence" do
      assert FuzzySearch.rank("lists", "lists") == 0
      assert FuzzySearch.rank("lists", "lis") == 1
      assert FuzzySearch.rank("lists", "ist") == 2
      assert FuzzySearch.rank("lists", "lss") == 3
    end

    test "returns nil when the characters are out of order or missing" do
      assert FuzzySearch.rank("lists", "tsil") == nil
      assert FuzzySearch.rank("lists", "listsx") == nil
    end

    test "ignores case" do
      assert FuzzySearch.rank("Elixir.Date", "elixir.date") == 0
      assert FuzzySearch.rank("date", "DT") == 3
    end

    test "matches multi-byte characters" do
      assert FuzzySearch.rank("zażółć", "zżć") == 3
    end
  end

  describe "matches?/2" do
    test "matches subsequences and treats a blank query as a match" do
      assert FuzzySearch.matches?("kernel", "krl")
      refute FuzzySearch.matches?("kernel", "lrk")
      assert FuzzySearch.matches?("kernel", "")
      assert FuzzySearch.matches?("kernel", nil)
    end
  end
end
