defmodule Voyager.MatchSpec.ElixirParserTest do
  use ExUnit.Case, async: true

  alias Voyager.MatchSpec

  @not_a_list {:error,
               {:unsupported, "dbg:fun2ms requires fun with single variable or list parameter"}}

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
        assert parse(source, :trace) == @not_a_list, source
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
                {:unsupported, "ets:fun2ms requires fun with single variable or tuple parameter"}}
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

    test "maps each arithmetic operator to its Erlang form" do
      for {elixir, erlang} <- [
            {"x + 2", {:+, :"$1", 2}},
            {"x - 2", {:-, :"$1", 2}},
            {"x * 2", {:*, :"$1", 2}},
            {"x / 2", {:/, :"$1", 2}},
            {"div(x, 2)", {:div, :"$1", 2}},
            {"rem(x, 2)", {:rem, :"$1", 2}},
            {"-x", {:-, :"$1"}}
          ] do
        assert parse("fn {x} when #{elixir} > 0 -> #{elixir} end", :table) ==
                 {:ok, [{{:"$1"}, [{:>, erlang, 0}], [erlang]}]},
               elixir
      end
    end

    test "folds constant arithmetic, as the Erlang fun does" do
      assert parse("fn {x} when x > 1 + 2 * -3 -> x end", :table) ==
               {:ok, [{{:"$1"}, [{:>, :"$1", -5}], [:"$1"]}]}
    end

    test "reads map fields and expands in, ranges and is_struct" do
      assert parse("fn {x} when x.key > 1 and x.a.b == 2 -> x end", :table) ==
               MatchSpec.parse_fun(
                 "fun({X}) when map_get(key, X) > 1 andalso map_get(b, map_get(a, X)) == 2 -> X end",
                 :erlang,
                 :table
               )

      source = "fn {x} when x in [:a, :b] or x in 1..3 or is_struct(x, URI) -> x end"
      assert {:ok, spec} = parse(source, :table)
      assert MatchSpec.check_compiles(spec, :table) == :ok
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
      assert {:error, {:unsupported, message}} = parse(~S|fn {x, :"$1"} -> x end|, :table)
      assert message =~ "'$1'"
    end

    test "refuses a variable the head does not bind" do
      for source <- ["fn {x} when x > y -> x end", "fn {x} -> y end", "fn {x} -> _ end"] do
        assert {:error, {:unsupported, _message}} = parse(source, :table), source
      end
    end

    test "refuses more or fewer than one parameter" do
      for source <- ["fn a, b -> a end", "fn a, b when a > b -> a end", "fn -> 1 end"] do
        assert parse(source, :trace) == @not_a_list, source
      end
    end

    test "refuses the forms whose expansion would run code on this node" do
      for source <- [
            ~S|fn {x} -> System.cmd("id", []) end|,
            "fn {x} -> Kernel.div(x, 2) end",
            "fn {x} -> Kernel.use(GenServer) end",
            ~S|fn {x} -> :"Elixir.Kernel".use(GenServer) end|,
            "fn {x} -> MyApp.Repo.config() end",
            "fn {x} -> import String\n upcase(x) end",
            "fn {x} -> require Logger\n Logger.info(x) end",
            "fn {x} -> %URI{} end",
            "fn {%URI{host: h}} -> h end",
            ~S|fn {x} -> "a#{x}" end|,
            "fn {x} -> &IO.puts/1 end"
          ] do
        assert {:error, {:unsupported, message}} = parse(source, :table), source
        assert message =~ "is not supported"
      end
    end

    test "refuses what a match spec cannot hold" do
      for source <- [
            ~S|fn {x} when x > :erlang.halt() -> x end|,
            "fn {x} -> :erlang.halt() end",
            "fn {x} -> use GenServer end",
            "fn {x} -> if x, do: 1 end",
            "fn {x} -> defmodule Foo do\n end end",
            "fn {x} -> case x do\n _ -> 1 end end",
            "fn {x} -> ^x end",
            ~S|fn {x} -> ~c"ab" end|,
            "fn {x} -> fn -> x end end",
            "fn {x} -> x.() end",
            "fn {x} -> x.key end",
            "fn {x} -> y = x end",
            "fn {%{^x => 1}} -> 1 end",
            "fn {<<a::8>>} -> a end",
            "fn {%{x | a: 1}} -> 1 end",
            "fn {%{1}} -> 1 end",
            "fn {x} -> %{x | a: 1} end",
            "fn {x} when get_tcw() > 1 -> x end",
            "fn {a} -> 1\n a, b -> 2 end"
          ] do
        assert {:error, {:unsupported, message}} = parse(source, :table), source
        assert is_binary(message)
      end
    end

    test "never sends" do
      name = :"probe_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      for source <- [
            "fn {x} when x == send(:#{name}, :leaked) -> x end",
            "fn {x} -> send(:#{name}, :leaked) end",
            ~s|fn {x} -> :erlang."!"(:#{name}, :leaked) end|
          ] do
        assert {:error, {:unsupported, _message}} = parse(source, :table), source
      end

      refute_received :leaked
    end

    test "returns an error when folded constants outgrow the parsing process" do
      shifts = Enum.map_join(1..20, ", ", fn _ -> "1 <<< 4000000" end)

      assert parse("fn {x} -> [#{shifts}] end", :table) == {:error, :limit_exceeded}
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

  describe "parse_fun/3 with :elixir fun2ms features" do
    test "binds the whole parameter with a top-level =" do
      for {source, type} <- [
            {"fn {k, _} = row -> {k, row} end", :table},
            {"fn row = {k, _} -> {k, row} end", :table}
          ] do
        assert parse(source, type) == {:ok, [{{:"$1", :_}, [], [{{:"$1", :"$_"}}]}]}, source
      end

      assert parse("fn [a] = args -> message(args) end", :trace) ==
               {:ok, [{[:"$1"], [], [{:message, :"$_"}]}]}
    end

    test "refuses = anywhere but the top of the head, or with a name bound twice" do
      for source <- ["fn {a = b} -> a end", "fn {a, _} = a -> a end", "fn {a} = {b} -> a end"] do
        assert {:error, {:unsupported, _message}} = parse(source, :table), source
      end
    end

    test "translates Elixir names to their Erlang forms" do
      for {elixir, erlang} <- [
            {"elem(x, 0)", {:element, 1, :"$1"}},
            {"elem(x, x)", {:element, {:+, :"$1", 1}, :"$1"}},
            {"is_map_key(x, :k)", {:is_map_key, :k, :"$1"}},
            {"is_nil(x)", {:==, :"$1", nil}},
            {"map_size(x)", {:map_size, :"$1"}},
            {":erlang.element(1, x)", {:element, 1, :"$1"}},
            {":erlang.xor(x, true)", {:xor, :"$1", true}},
            {"x &&& 1", {:band, :"$1", 1}},
            {"band(x, 1)", {:band, :"$1", 1}},
            {"~~~x", {:bnot, :"$1"}},
            {"+x", {:+, :"$1"}},
            {"object()", :"$_"},
            {"bindings()", :"$*"}
          ] do
        assert parse("fn {x} -> #{elixir} end", :table) == {:ok, [{{:"$1"}, [], [erlang]}]},
               elixir
      end
    end

    test "keeps trace actions in a body and refuses them in a guard" do
      assert parse("fn [a] -> return_trace(); message(caller()); display(a) end", :trace) ==
               {:ok, [{[:"$1"], [], [{:return_trace}, {:message, {:caller}}, {:display, :"$1"}]}]}

      assert {:error, {:unsupported, _message}} =
               parse("fn [a] when message(a) -> true end", :trace)
    end

    test "leaves an action in a table body for check_compiles/2 to refuse, as ms_transform does" do
      assert {:ok, spec} = parse("fn {a} -> return_trace() end", :table)

      assert spec ==
               elem(MatchSpec.parse_fun("fun({A}) -> return_trace() end", :erlang, :table), 1)

      assert {:error, {:compile, [_ | _]}} = MatchSpec.check_compiles(spec, :table)
    end

    test "builds literal bit syntax" do
      for {elixir, binary} <- [
            {"<<1, 2>>", <<1, 2>>},
            {"<<1::16-little>>", <<1, 0>>},
            {"<<3::size(4)-unit(2)>>", <<3>>},
            {~S|<<"ab", "c"::binary>>|, "abc"},
            {~S|<<"ć"::utf8>>|, "ć"},
            {"<<1.5::32>>", <<1.5::float-32>>},
            {"<<-1::8>>", <<255>>},
            {"<< <<1>>::binary, 2>>", <<1, 2>>}
          ] do
        assert parse("fn {x} when x == #{elixir} -> x end", :table) ==
                 {:ok, [{{:"$1"}, [{:==, :"$1", binary}], [:"$1"]}]},
               elixir
      end
    end

    test "refuses bit syntax that is not a literal or too big" do
      assert {:error, {:unsupported, _}} = parse("fn {x} -> <<x::8>> end", :table)
      assert {:error, {:unsupported, _}} = parse("fn {x} -> <<1.5::8>> end", :table)

      for source <- [
            "fn {x} -> <<0::524289>> end",
            "fn {x} -> <<0::2049-unit(256)>> end",
            "fn {x} -> <<0::size(x)>> end"
          ] do
        assert parse(source, :table) ==
                 {:error,
                  {:syntax, "binary segments must have an integer size of at most 524288 bits"}},
               source
      end
    end
  end

  test "matches what the Erlang fun gives" do
    for {elixir, erlang, type} <- [
          {"fn {a, _} = x -> x end", "fun({A, _} = X) -> X end", :table},
          {"fn {a} -> {object(), bindings()} end", "fun({A}) -> {object(), bindings()} end",
           :table},
          {"fn {a} when elem(a, 0) == 2 and (is_map_key(a, :k) and a.k > 1) -> a end",
           "fun({A}) when element(1, A) == 2 andalso is_map_key(k, A) andalso map_get(k, A) > 1 -> A end",
           :table},
          {"fn [a] -> return_trace(); message(caller()); current_stacktrace(2) end",
           "fun([A]) -> return_trace(), message(caller()), current_stacktrace(2) end", :trace},
          {"fn [a] -> message(get_tcw())\n is_seq_trace() end",
           "fun([A]) -> message(get_tcw()), is_seq_trace() end", :trace},
          {"fn [MyApp.Repo, :all, [q | _]] -> message(q) end",
           "fun(['Elixir.MyApp.Repo', all, [Q | _]]) -> message(Q) end", :trace},
          {"fn args = [a] -> message(args) end", "fun(Args = [A]) -> message(Args) end", :trace},
          {"fn {a} when :erlang.xor(a, true) when (a &&& 1) == 1 when ~~~a > 1 -> a end",
           "fun({A}) when A xor true; A band 1 == 1; bnot A > 1 -> A end", :table},
          {"fn {a} -> {abs(a), hd(a), tl(a), length(a), round(a), trunc(a), float(a), max(a, 1), min(a, 2), node(), node(a), self(), byte_size(a), bit_size(a), map_size(a), binary_part(a, 0, 1)} end",
           "fun({A}) -> {abs(A), hd(A), tl(A), length(A), round(A), trunc(A), float(A), max(A, 1), min(A, 2), node(), node(A), self(), byte_size(A), bit_size(A), map_size(A), binary_part(A, 0, 1)} end",
           :table},
          {"fn {a} -> {bxor(a, 1), bnot(a), bsl(a, 2), bsr(a, 1), a <<< 1, a >>> 1, a ||| 2} end",
           "fun({A}) -> {A bxor 1, bnot A, A bsl 2, A bsr 1, A bsl 1, A bsr 1, A bor 2} end",
           :table},
          {~S|fn {a} when a == <<1, 2::16-little, 3::size(4)-unit(2), "ab", 1.5::32>> -> a end|,
           ~S|fun({A}) when A == <<1, 2:16/little, 3:4/unit:2, "ab", 1.5:32/float>> -> A end|,
           :table},
          {"fn [a, _] when a > 10 -> true end", "fun([A, _]) when A > 10 -> true end", :trace},
          {"fn args -> true end", "fun(Args) -> true end", :trace},
          {"fn {k, v} when v > 1 -> k end", "fun({K, V}) when V > 1 -> K end", :table},
          {"fn {k, v} when v >= 1 when k == :a -> {k, v} end",
           "fun({K, V}) when V >= 1; K == a -> {K, V} end", :table},
          {"fn {k, v} when k !== v and is_atom(k) -> [k] end",
           "fun({K, V}) when K =/= V andalso is_atom(K) -> [K] end", :table},
          {~S|fn {k, %{a: v}} when v != "x" -> %{k: v} end|,
           ~S|fun({K, #{a := V}}) when V /= <<"x">> -> #{k => V} end|, :table},
          {"fn {k, v} when v + 1 > 10 and rem(v, 2) == 0 -> {k * 2, div(v, 3), -k, v / 2} end",
           "fun({K, V}) when V + 1 > 10 andalso V rem 2 == 0 -> {K * 2, V div 3, -K, V / 2} end",
           :table}
        ] do
      assert parse(elixir, type) == MatchSpec.parse_fun(erlang, :erlang, type), elixir
    end
  end

  test "every translated spec compiles for its type" do
    for {source, type} <- [
          {"fn [a, _] when a > 10 and not is_atom(a) -> true end", :trace},
          {"fn args when is_list(args) -> true end", :trace},
          {"fn {k, v} when v > 1 when k == :a -> {k, [v]} end", :table},
          {~S|fn {k, %{a: v}} when k == {:b, :"$1"} -> %{k: v} end|, :table},
          {"fn [a, b] when a + b > 1 + 2 and rem(-a, 2) == 0 -> true end", :trace},
          {"fn {k, v} -> {k * 2, div(v, 3), v / 2} end", :table},
          {"fn {k, _} = row when elem(row, 0) == k and is_map_key(k, :a) -> object() end",
           :table},
          {"fn [a] = args when map_size(a) > 1 -> return_trace(); message(args) end", :trace},
          {"fn {a} when a == <<1, 2::16-little>> or a.key == 1 -> {a &&& 1, is_nil(a)} end",
           :table}
        ] do
      assert {:ok, spec} = parse(source, type), source
      assert MatchSpec.check_compiles(spec, type) == :ok, source
    end
  end
end
