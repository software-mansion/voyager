defmodule Voyager.MatchSpec.ElixirParserTest do
  use ExUnit.Case, async: true

  alias Voyager.MatchSpec

  defp parse(source, type), do: MatchSpec.parse_fun(source, :elixir, type)

  describe "parse_fun/3 with :elixir and :trace" do
    test "turns the argument list and a guard into a clause" do
      assert parse("fn [a, _] when a > 10 -> true end", :trace) ==
               {:ok, [{[:"$1", :_], [{:>, :"$1", 10}], [true]}]}
    end

    test "binds the whole argument list to a variable" do
      assert parse("fn args when is_list(args) -> true end", :trace) ==
               {:ok, [{:"$1", [{:is_list, :"$1"}], [true]}]}
    end

    test "translates every clause" do
      assert parse("fn [a] when a > 1 -> true\n _ -> false end", :trace) ==
               {:ok, [{[:"$1"], [{:>, :"$1", 1}], [true]}, {:_, [], [false]}]}
    end

    test "refuses a parameter that is not a list or a variable" do
      for source <- ["fn {k, v} -> k end", "fn %{k: v} -> v end", "fn :atom -> 1 end"] do
        assert parse(source, :trace) ==
                 {:error,
                  {:unsupported,
                   "the parameter must be a variable or a list of the call's arguments"}},
               source
      end
    end
  end

  describe "parse_fun/3 with :elixir and :table" do
    test "turns the row and a guard into a clause" do
      assert parse("fn {k, v} when v > 1 -> k end", :table) ==
               {:ok, [{{:"$1", :"$2"}, [{:>, :"$2", 1}], [:"$1"]}]}
    end

    test "matches n-tuples, lists, maps, literals and repeated variables" do
      source = ~S'fn {k, k, [1 | t], %{k: v}, "b", -2.5, :ok, nil} -> v end'

      assert parse(source, :table) ==
               {:ok,
                [{{:"$1", :"$1", [1 | :"$2"], %{k: :"$3"}, "b", -2.5, :ok, nil}, [], [:"$3"]}]}
    end

    test "matches anything with _ and binds _name like any variable" do
      assert parse("fn {_, _a, _a, x} -> x end", :table) ==
               {:ok, [{{:_, :"$1", :"$1", :"$2"}, [], [:"$2"]}]}

      assert parse("fn {_a, _a} -> true end", :table) ==
               MatchSpec.parse_fun("fun({_A, _A}) -> true end", :erlang, :table)
    end

    test "refuses a parameter that is not a tuple or a variable" do
      assert parse("fn [k] -> k end", :table) ==
               {:error,
                {:unsupported, "the parameter must be a variable or a tuple matching the row"}}
    end
  end

  describe "parse_fun/3 with :elixir guards" do
    test "maps each comparison to its Erlang operator" do
      for {elixir, erlang} <- [
            {"==", :==},
            {"!=", :"/="},
            {"===", :"=:="},
            {"!==", :"=/="},
            {"<", :<},
            {">", :>},
            {"<=", :"=<"},
            {">=", :>=}
          ] do
        assert parse("fn {x} when x #{elixir} 1 -> x end", :table) ==
                 {:ok, [{{:"$1"}, [{erlang, :"$1", 1}], [:"$1"]}]},
               elixir
      end
    end

    test "translates and, or, not and type checks" do
      source = "fn {x, y} when is_integer(x) and (y == :a or not is_atom(y)) -> x end"

      assert parse(source, :table) ==
               {:ok,
                [
                  {{:"$1", :"$2"},
                   [
                     {:andalso, {:is_integer, :"$1"},
                      {:orelse, {:==, :"$2", :a}, {:not, {:is_atom, :"$2"}}}}
                   ], [:"$1"]}
                ]}
    end

    test "gives each extra when its own clause" do
      assert parse("fn {x} when x > 1 when x == :a -> x end", :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:>, :"$1", 1}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", :a}], [:"$1"]}
                ]}
    end

    test "builds tuples and lists and wraps reserved atoms" do
      assert parse(~S|fn {x} when x == {:a, [1, "b"]} or x == :"$1" -> x end|, :table) ==
               {:ok,
                [
                  {{:"$1"},
                   [{:orelse, {:==, :"$1", {{:a, [1, "b"]}}}, {:==, :"$1", {:const, :"$1"}}}],
                   [:"$1"]}
                ]}
    end
  end

  describe "parse_fun/3 with :elixir bodies" do
    test "keeps every expression of a block" do
      assert parse("fn [a] -> a\n true end", :trace) == {:ok, [{[:"$1"], [], [:"$1", true]}]}
    end

    test "builds tuples, n-tuples, lists and maps" do
      assert parse("fn {k, v} -> {k, [v | k], {k, v, 1}, %{key: v}} end", :table) ==
               {:ok,
                [
                  {{:"$1", :"$2"}, [],
                   [{{:"$1", [:"$2" | :"$1"], {{:"$1", :"$2", 1}}, %{key: :"$2"}}}]}
                ]}
    end

    test "wraps reserved atoms" do
      assert parse(~S|fn {x} -> :"$1" end|, :table) == {:ok, [{{:"$1"}, [], [{:const, :"$1"}]}]}
    end
  end

  describe "parse_fun/3 with :elixir errors" do
    test "refuses a reserved atom in the head" do
      assert parse(~S|fn {x, :"$1"} -> x end|, :table) ==
               {:error, {:unsupported, ~S|:"$1" is reserved for match variables|}}
    end

    test "refuses a variable the head does not bind" do
      for source <- ["fn {x} when x > y -> x end", "fn {x} -> y end", "fn {x} -> _ end"] do
        assert {:error, {:unsupported, message}} = parse(source, :table), source
        assert message =~ "is not bound by the parameter"
      end
    end

    test "refuses more or fewer than one parameter" do
      for {source, count} <- [
            {"fn a, b -> a end", 2},
            {"fn a, b when a > b -> a end", 2},
            {"fn -> 1 end", 0}
          ] do
        assert parse(source, :trace) ==
                 {:error, {:unsupported, "expected one parameter, got #{count}"}},
               source
      end
    end

    test "never evaluates code" do
      for source <- [
            ~S|fn {x} -> System.cmd("id", []) end|,
            ~S|fn {x} when x > :erlang.halt() -> x end|,
            "fn {x} -> send(self(), x) end",
            "fn {x} -> x + 1 end",
            "fn {x} -> ^x end",
            ~S|fn {x} -> "a#{x}" end|,
            ~S|fn {x} -> ~c"ab" end|,
            "fn {x} -> MyApp.Repo end",
            "fn {x} -> &IO.puts/1 end",
            "fn {x} -> fn -> x end end",
            "fn {x} -> 1..2 end",
            "fn {%{^x => 1}} -> 1 end",
            "fn {<<a::8>>} -> a end",
            "fn {%{x | a: 1}} -> 1 end",
            "fn {%{1}} -> 1 end",
            "fn {x} -> %{x | a: 1} end",
            "fn {x} when x == %{x, a: 1} -> x end",
            "fn {__MODULE__} -> 1 end"
          ] do
        assert {:error, {:unsupported, message}} = parse(source, :table), source
        assert message =~ "is not supported"
      end
    end

    test "refuses anything but one fn" do
      for source <- ["[{:_, [], []}]", "x", ":ok"] do
        assert parse(source, :table) == {:error, {:syntax, "expected one fn ... end"}}, source
      end
    end

    test "reports syntax errors" do
      for source <- ["fn x -> x", "fn x x end", "1 +", ""] do
        assert {:error, {:syntax, message}} = parse(source, :table), inspect(source)
        assert is_binary(message)
      end
    end

    test "applies the input limits" do
      assert parse(String.duplicate(" ", 4_097), :table) == {:error, :too_large}
      assert parse(<<"fn ", 255, " -> 1 end">>, :table) == {:error, {:syntax, "not valid UTF-8"}}
    end
  end

  test "matches what the Erlang fun gives" do
    for {elixir, erlang, type} <- [
          {"fn [a, _] when a > 10 -> true end", "fun([A, _]) when A > 10 -> true end", :trace},
          {"fn args -> true end", "fun(Args) -> true end", :trace},
          {"fn {k, v} when v > 1 -> k end", "fun({K, V}) when V > 1 -> K end", :table},
          {"fn {k, v} when v >= 1 when k == :a -> {k, v} end",
           "fun({K, V}) when V >= 1; K == a -> {K, V} end", :table},
          {"fn {k, v} when k !== v and is_atom(k) -> [k] end",
           "fun({K, V}) when K =/= V andalso is_atom(K) -> [K] end", :table},
          {~S|fn {k, %{a: v}} when v != "x" -> %{k: v} end|,
           ~S|fun({K, #{a := V}}) when V /= <<"x">> -> #{k => V} end|, :table}
        ] do
      assert parse(elixir, type) == MatchSpec.parse_fun(erlang, :erlang, type), elixir
    end
  end

  test "every translated spec compiles for its type" do
    for {source, type} <- [
          {"fn [a, _] when a > 10 and not is_atom(a) -> true end", :trace},
          {"fn args when is_list(args) -> true end", :trace},
          {"fn {k, v} when v > 1 when k == :a -> {k, [v]} end", :table},
          {~S|fn {k, %{a: v}} when k == {:b, :"$1"} -> %{k: v} end|, :table}
        ] do
      assert {:ok, spec} = parse(source, type), source
      assert MatchSpec.check_compiles(spec, type) == :ok, source
    end
  end
end
