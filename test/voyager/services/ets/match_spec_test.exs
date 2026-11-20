defmodule Voyager.Services.Ets.MatchSpecTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Ets.MatchSpec

  describe "parse/1" do
    test "returns the spec with its atoms encoded" do
      spec = ~S([{{'$1', '$2', active}, [{'>', '$2', 10}], ['$1']}])

      assert MatchSpec.parse(spec) ==
               {:ok, [{{:"$1", :"$2", tag(:active)}, [{tag(:>), :"$2", 10}], [:"$1"]}]}
    end

    test "rejects what Voyager.MatchSpec.parse/1 refuses, with its message" do
      for {input, detail} <- [
            {<<255>>, "not valid UTF-8"},
            {String.duplicate("a", 4_097), "longer than 4096 bytes"},
            {"[{X, [], [X]}]", "bad term"},
            {"[{'$1', [], [<<0:99999999999999>>]}]",
             "binary segments must have an integer size of at most 524288 bits"}
          ] do
        assert MatchSpec.parse(input) == {:error, {:invalid_match_spec, detail}}, input
      end
    end

    test "rejects a spec that does not compile for a table" do
      assert MatchSpec.parse("[{'$1', [], ['$7']}]") ==
               {:error, {:invalid_match_spec, "Variable $7 is unbound."}}

      assert {:error, {:invalid_match_spec, _detail}} =
               MatchSpec.parse("[{'$1', [], [{message, '$1'}]}]")
    end

    test "rejects a spec that encodes to more than the agent takes" do
      assert MatchSpec.parse("[{'_', [], [<<0:524288>>]}]") ==
               {:error, {:invalid_match_spec, "encodes to more than 65536 bytes"}}
    end

    test "rejects a spec that is not a single clause" do
      assert MatchSpec.parse("[{'$1', [], ['$1']}, {'$2', [], ['$2']}]") ==
               {:error, {:invalid_match_spec, "expected one {head, guards, body} clause"}}
    end

    test "rejects a term that is not a clause list" do
      for input <- ["42", "[]", "[{'$1', [], '$1'}]"] do
        assert MatchSpec.parse(input) ==
                 {:error,
                  {:invalid_match_spec, "expected a list of one {head, guards, body} clause"}}
      end
    end
  end

  defp tag(atom), do: {:"$voyager_atom", Atom.to_string(atom)}
end
