defmodule Voyager.Services.Ets.MatchSpecTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Ets.MatchSpec

  describe "parse/1" do
    test "parses the match-all spec" do
      assert MatchSpec.parse("[{'$1', [], ['$1']}].") == {:ok, [{:"$1", [], [:"$1"]}]}
    end

    test "parses a head, guards and body" do
      spec = ~S([{{'$1', '$2'}, [{'>', '$2', 10}], ['$1']}])

      assert MatchSpec.parse(spec) ==
               {:ok, [{{:"$1", :"$2"}, [{:>, :"$2", 10}], [:"$1"]}]}
    end

    test "parses binaries, negative numbers and nested terms" do
      spec = ~S([{{'$1', <<"a">>, [-3, {ok, #{k => '$2'}}]}, [], ['$_']}])

      assert {:ok, [{head, [], [:"$_"]}]} = MatchSpec.parse(spec)
      assert head == {:"$1", "a", [-3, {:ok, %{k: :"$2"}}]}
    end

    test "adds a missing trailing dot" do
      assert MatchSpec.parse("[{'$1', [], ['$1']}]") == {:ok, [{:"$1", [], [:"$1"]}]}
    end

    test "rejects a call" do
      assert {:error, {:invalid_match_spec, _}} = MatchSpec.parse("os:cmd(\"whoami\").")
    end

    test "rejects a variable" do
      assert {:error, {:invalid_match_spec, _}} = MatchSpec.parse("[{X, [], [X]}].")
    end

    test "rejects a spec that is not a single clause" do
      assert {:error, {:invalid_match_spec, detail}} =
               MatchSpec.parse("[{'$1', [], ['$1']}, {'$2', [], ['$2']}]")

      assert detail =~ "one {head, guards, body} clause"
    end

    test "rejects a term that is not a clause list" do
      assert {:error, {:invalid_match_spec, _}} = MatchSpec.parse("42")
      assert {:error, {:invalid_match_spec, _}} = MatchSpec.parse("[{'$1', [], '$1'}]")
    end

    test "rejects an empty spec" do
      assert {:error, {:invalid_match_spec, _}} = MatchSpec.parse("")
    end

    test "rejects a spec over the byte cap" do
      assert {:error, {:invalid_match_spec, detail}} =
               MatchSpec.parse(String.duplicate("a", 5_000))

      assert detail =~ "longer than"
    end
  end
end
