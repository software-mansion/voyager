defmodule Voyager.MatchSpec.UtilsTest do
  use ExUnit.Case, async: true

  alias Voyager.MatchSpec.Utils

  @too_big {:error, {:syntax, "binary segments must have an integer size of at most 524288 bits"}}

  defp segment(value, size \\ :default, types \\ :default),
    do: {:bin_element, 1, value, size, types}

  defp int(n), do: {:integer, 1, n}

  describe "check_segments/1" do
    test "accepts default and literal sizes up to the cap, at any depth" do
      for abstract <- [
            [],
            {:atom, 1, :ok},
            {:bin, 1, [segment(int(1))]},
            {:bin, 1, [segment(int(0), int(0))]},
            {:bin, 1, [segment(int(0), int(524_288))]},
            {:bin, 1, [segment(int(0), int(524_288), [:integer, :little])]},
            {:bin, 1, [segment(int(0), {:char, 1, ?a})]},
            {:bin, 1, [segment(int(0), int(65_536), [:binary])]},
            {:bin, 1, [segment(int(0), int(524_288), [:binary, {:unit, 1}])]},
            [{:tuple, 1, [{:bin, 1, [segment(int(0), int(2048), [{:unit, 256}])]}]}]
          ] do
        assert Utils.check_segments(abstract) == :ok, inspect(abstract)
      end
    end

    test "refuses a size over the cap once the unit is counted" do
      for abstract <- [
            {:bin, 1, [segment(int(0), int(524_289))]},
            {:bin, 1, [segment(int(0), int(65_537), [:binary])]},
            {:bin, 1, [segment(int(0), int(65_537), [:bytes])]},
            {:bin, 1, [segment(int(0), int(2049), [{:unit, 256}])]},
            {:bin, 1, [segment(int(0), int(65_536), [:binary, {:unit, 9}])]},
            {:bin, 1, [segment(int(1)), segment(int(0), int(524_289))]}
          ] do
        assert Utils.check_segments(abstract) == @too_big, inspect(abstract)
      end
    end

    test "refuses a size that is not an integer literal" do
      for size <- [
            {:var, 1, :Size},
            {:op, 1, :bsl, int(1), int(40)},
            {:op, 1, :-, int(1)},
            {:float, 1, 8.0}
          ] do
        assert Utils.check_segments({:bin, 1, [segment(int(0), size)]}) == @too_big,
               inspect(size)
      end
    end

    test "finds an oversized segment nested in a value, a tuple or a list" do
      inner = {:bin, 1, [segment(int(0), int(99_999_999_999_999))]}

      for abstract <- [
            {:bin, 1, [segment(inner, :default, [:binary])]},
            {:tuple, 1, [int(1), inner]},
            [{:cons, 1, inner, {nil, 1}}]
          ] do
        assert Utils.check_segments(abstract) == @too_big, inspect(abstract)
      end
    end
  end
end
