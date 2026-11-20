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

    test "keeps remote guard calls, folds shifts and builds sized segments" do
      source = "fun({X}) when erlang:is_atom(X); X > 1 bsl 64; X == <<1:16>> -> X end"

      assert parse(source, :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:is_atom, :"$1"}], [:"$1"]},
                  {{:"$1"}, [{:>, :"$1", 18_446_744_073_709_551_616}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", <<0, 1>>}], [:"$1"]}
                ]}
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
            {"fun() -> ok end", :table},
            {"fun({X}) -> list_to_atom(X) end", :table},
            {"fun({X}) when tuple_size(X) > 1 -> X end", :table},
            {"fun({X}) when is_boolean(X) -> X end", :table},
            {"fun([X]) -> case X of _ -> X end end", :trace},
            {~S|fun(_) -> os:cmd("id") end|, :trace}
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

    test "refuses the ! operator, which ms_transform would send" do
      name = :"probe_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert parse("fun([X]) when X == (#{name} ! leaked) -> true end", :trace) ==
               {:error, {:syntax, "the ! operator is not allowed"}}

      refute_received :leaked
    end

    test "keeps a ! that is an atom, a string or a char" do
      assert parse(~S|fun({X}) when X == '!'; X == "!"; X == $! -> X end|, :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:==, :"$1", :!}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", ~c"!"}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", ?!}], [:"$1"]}
                ]}
    end

    test "refuses a segment size too big or not a literal before building it" do
      for source <- [
            "fun({X}) when X == <<0:99999999999999>> -> X end",
            "fun({X}) -> <<1:X>> end"
          ] do
        assert parse(source, :table) ==
                 {:error,
                  {:syntax, "binary segments must have an integer size of at most 524288 bits"}},
               source
      end
    end

    test "refuses anything but one anonymous fun" do
      for source <- [
            "[{'_', [], []}]",
            "ok",
            "fun(X) -> X end, fun(Y) -> Y end",
            "fun F({X}) -> X end",
            "fun erlang:halt/0"
          ] do
        assert parse(source, :table) == {:error, {:syntax, "expected one fun ... end"}}, source
      end
    end

    test "adds a missing trailing dot" do
      assert parse("fun({X}) -> X end", :table) == parse("fun({X}) -> X end. ", :table)
    end

    test "reports syntax errors" do
      for source <- ["fun(X) -> X", "fun(X) X end", "'unterminated", ""] do
        assert {:error, {:syntax, message}} = parse(source, :table), inspect(source)
        assert is_binary(message)
      end
    end
  end
end
