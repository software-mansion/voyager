defmodule Voyager.MatchSpec.ErlangParserTest do
  use ExUnit.Case, async: true

  alias Voyager.MatchSpec

  defp parse(source, type), do: MatchSpec.parse_fun(source, :erlang, type)

  describe "parse_fun/3 with :erlang and :trace" do
    test "turns the argument list and a guard into a clause" do
      assert parse("fun([A, _]) when A > 10 -> true end", :trace) ==
               {:ok, [{[:"$1", :_], [{:>, :"$1", 10}], [true]}]}
    end

    test "keeps trace actions in the body" do
      assert parse("fun([A]) when A > 10 -> return_trace(), message(A); (_) -> true end", :trace) ==
               {:ok,
                [
                  {[:"$1"], [{:>, :"$1", 10}], [{:return_trace}, {:message, :"$1"}]},
                  {:_, [], [true]}
                ]}
    end

    test "binds the whole argument list to a variable" do
      assert parse("fun(Args) when length(Args) > 1 -> true end", :trace) ==
               {:ok, [{:"$1", [{:>, {:length, :"$1"}, 1}], [true]}]}
    end

    test "refuses a parameter that is not a list or a variable" do
      assert parse("fun({K, V}) -> K end", :trace) ==
               {:error,
                {:unsupported, "dbg:fun2ms requires fun with single variable or list parameter"}}
    end
  end

  describe "parse_fun/3 with :erlang and :table" do
    test "turns the row and a guard into a clause" do
      assert parse("fun({K, V}) when V > 1 -> K end", :table) ==
               {:ok, [{{:"$1", :"$2"}, [{:>, :"$2", 1}], [:"$1"]}]}
    end

    test "splits guard sequences into clauses and keeps guard lists" do
      assert parse("fun({K, V}) when is_integer(V), V > 1; K == a -> {K, V} end", :table) ==
               {:ok,
                [
                  {{:"$1", :"$2"}, [{:is_integer, :"$2"}, {:>, :"$2", 1}], [{{:"$1", :"$2"}}]},
                  {{:"$1", :"$2"}, [{:==, :"$1", :a}], [{{:"$1", :"$2"}}]}
                ]}
    end

    test "matches literals, lists, maps and repeated variables" do
      assert parse(~S'fun({K, K, [1 | T], #{k := V}, <<"b">>, -2.5}) -> object() end', :table) ==
               {:ok, [{{:"$1", :"$1", [1 | :"$2"], %{k: :"$3"}, "b", -2.5}, [], [:"$_"]}]}
    end

    test "wraps constant tuples and reserved atoms in the body" do
      assert parse("fun({K}) when K == {a, b} -> '$1' end", :table) ==
               {:ok, [{{:"$1"}, [{:==, :"$1", {{:a, :b}}}], [const: :"$1"]}]}
    end

    test "refuses a parameter that is not a tuple or a variable" do
      assert parse("fun([K]) -> K end", :table) ==
               {:error,
                {:unsupported, "ets:fun2ms requires fun with single variable or tuple parameter"}}
    end
  end

  describe "parse_fun/3 with :erlang errors" do
    test "refuses a variable the head does not bind" do
      assert parse("fun({K}) when K > X -> K end", :table) ==
               {:error,
                {:unsupported, "the variable X is unbound, cannot translate into match_spec"}}
    end

    test "refuses reserved atoms in the head" do
      assert {:error, {:unsupported, message}} = parse("fun({X, '$1'}) -> X end", :table)
      assert message =~ "'$1'"
    end

    test "refuses what ms_transform cannot translate" do
      for {source, type} <- [
            {"fun(A, B) -> A end", :table},
            {"fun({X}) -> #r{} end", :table},
            {"fun({X}) when X = 1 -> X end", :table},
            {"fun({X}) -> list_to_atom(X) end", :table},
            {"fun([X]) -> case X of _ -> X end end", :trace}
          ] do
        assert {:error, {:unsupported, message}} = parse(source, type), source
        assert is_binary(message)
      end
    end

    test "returns an error where ms_transform raises" do
      for {source, type} <- [
            {"fun({f(x)}) -> true end", :table},
            {"fun({1 + 2}) -> true end", :table},
            {"fun({-X}) -> true end", :table},
            {"fun({[X || X <- []]}) -> true end", :table},
            {"fun([f(x)]) -> true end", :trace}
          ] do
        assert parse(source, type) ==
                 {:error, {:unsupported, "the fun cannot be turned into a match spec"}},
               source
      end
    end

    test "refuses remote calls, sized binaries and shifts before translating" do
      for {source, message} <- [
            {~S|fun(_) -> os:cmd("id") end|, "calls and sized binary segments are not allowed"},
            {"fun({X}) when X == <<0:99999999999999>> -> X end",
             "calls and sized binary segments are not allowed"},
            {"fun({X}) when X > 1 bsl 4000000 -> X end", "bsl and bsr are not allowed"},
            {"fun({X}) -> 1 bsr -4000000 end", "bsl and bsr are not allowed"}
          ] do
        assert parse(source, :table) == {:error, {:syntax, message}}, source
      end
    end

    test "refuses anything but one fun" do
      for source <- ["[{'_', [], []}]", "ok", "fun(X) -> X end, fun(Y) -> Y end"] do
        assert parse(source, :table) == {:error, {:syntax, "expected one fun ... end"}}, source
      end
    end

    test "reports syntax errors" do
      for source <- ["fun(X) -> X", "fun(X) X end", "'unterminated", ""] do
        assert {:error, {:syntax, message}} = parse(source, :table), inspect(source)
        assert is_binary(message)
      end
    end

    test "applies the input limits" do
      assert parse(String.duplicate(" ", 4_097), :table) == {:error, :too_large}

      assert parse(<<"fun(", 255, ") -> 1 end">>, :table) ==
               {:error, {:syntax, "not valid UTF-8"}}
    end
  end

  test "every translated spec compiles for its type" do
    for {source, type} <- [
          {"fun([A, _]) when A > 10 -> return_trace() end", :trace},
          {"fun(Args) -> message(Args) end", :trace},
          {"fun({K, V}) when V > 1; K == a -> {K, V} end", :table},
          {"fun({K, _}) -> object() end", :table}
        ] do
      assert {:ok, spec} = parse(source, type), source
      assert MatchSpec.check_compiles(spec, type) == :ok, source
    end
  end
end
