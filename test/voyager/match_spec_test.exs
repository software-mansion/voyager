defmodule Voyager.MatchSpecTest do
  use ExUnit.Case, async: true

  alias Voyager.MatchSpec

  @tag_atom :"$voyager_atom"
  @not_specs [
    [],
    42,
    :foo,
    "[]",
    %{},
    {:_, [], []},
    [:not_a_clause],
    [{:_, []}],
    [{:_, [], [], []}],
    [{:_, :guards, []}],
    [{:_, [], :body}],
    [{:_, [], []} | :tail],
    [{:_, [:a | :b], []}],
    [{:_, [], [:a | :b]}],
    [{:_, [], []}, :not_a_clause]
  ]

  describe "parse/1" do
    test "parses a head, guards and body" do
      assert MatchSpec.parse(~S([{{'$1', '$2'}, [{'>', '$2', 10}], ['$1']}])) ==
               {:ok, [{{:"$1", :"$2"}, [{:>, :"$2", 10}], [:"$1"]}]}
    end

    test "parses every literal Erlang term" do
      input =
        ~S([{{<<"a">>, -3, 1.5, -2.0e3, "ab", $c, #{k => '$2'}, [1 | t], 'Quoted atom'}, [], []}])

      assert MatchSpec.parse(input) ==
               {:ok,
                [
                  {{"a", -3, 1.5, -2.0e3, ~c"ab", ?c, %{k: :"$2"}, [1 | :t], :"Quoted atom"}, [],
                   []}
                ]}
    end

    test "parses unicode atoms and binaries" do
      assert MatchSpec.parse(~S(['zażółć', <<"ćma"/utf8>>])) == {:ok, [:zażółć, "ćma"]}
    end

    test "returns a term of any shape" do
      assert MatchSpec.parse("42") == {:ok, 42}
      assert MatchSpec.parse("[]") == {:ok, []}
      assert MatchSpec.parse("{a, b}") == {:ok, {:a, :b}}
    end

    test "parses empty terms and integers in another base" do
      assert MatchSpec.parse(~S([{}, #{}, "", <<>>, <<0:0>>, 16#ff])) ==
               {:ok, [{}, %{}, [], "", "", 255]}
    end

    test "skips a leading comment" do
      assert MatchSpec.parse("% all rows\n[{'$1', [], ['$1']}]") == {:ok, [{:"$1", [], [:"$1"]}]}
    end

    test "adds a missing trailing dot and ignores trailing whitespace" do
      for input <- [
            "[{'$1', [], ['$1']}]",
            "[{'$1', [], ['$1']}].",
            "[{'$1', [], ['$1']}] .\n\t "
          ] do
        assert MatchSpec.parse(input) == {:ok, [{:"$1", [], [:"$1"]}]}, inspect(input)
      end
    end

    test "never evaluates code" do
      for input <- [
            ~S|os:cmd("whoami")|,
            ~S|erlang:halt()|,
            ~S|[{'_', [], [os:cmd("id")]}]|,
            "fun() -> ok end",
            "1 + 2",
            "X",
            "[{X, [], [X]}]",
            "#r{a = 1}",
            "<<X:8>>",
            "begin ok end",
            "a = b"
          ] do
        assert {:error, {:syntax, message}} = MatchSpec.parse(input), inspect(input)
        assert is_binary(message)
      end
    end

    test "rejects malformed input" do
      for input <- [
            "",
            "  ",
            ".",
            "[{'$1', [], ['$1']}",
            "'unterminated",
            "a. b.",
            "{a,,}",
            "<<0:-1>>",
            "[] % a trailing comment hides the added dot"
          ] do
        assert {:error, {:syntax, _message}} = MatchSpec.parse(input), inspect(input)
      end
    end

    test "rejects invalid UTF-8 without raising" do
      assert MatchSpec.parse(<<"[", 255, "]">>) == {:error, {:syntax, "not valid UTF-8"}}
    end

    test "builds sized binary segments of up to 524288 bits, size times unit" do
      assert MatchSpec.parse("[<<1:16, 2:4/unit:2>>, <<1:16/little>>]") ==
               {:ok, [<<0, 1, 2>>, <<1, 0>>]}

      for input <- ["<<0:524288>>", "<<0:2048/unit:256>>"] do
        assert {:ok, binary} = MatchSpec.parse(input), input
        assert byte_size(binary) == 65_536
      end
    end

    test "refuses a segment too big before building it" do
      assert MatchSpec.parse("<<0:99999999999999>>") ==
               {:error,
                {:syntax, "binary segments must have an integer size of at most 524288 bits"}}
    end

    test "returns an error when the term outgrows the parsing process" do
      input = "[" <> Enum.map_join(1..200, ",", fn _ -> "<<0:524288>>" end) <> "]"

      assert MatchSpec.parse(input) == {:error, :limit_exceeded}
    end

    test "accepts 4096 bytes and refuses one more, counting bytes and not characters" do
      term = "[{'$1', [], ['$1']}]"
      at_cap = term <> String.duplicate(" ", 4_096 - byte_size(term))

      assert byte_size(at_cap) == 4_096
      assert {:ok, _spec} = MatchSpec.parse(at_cap)
      assert MatchSpec.parse(at_cap <> " ") == {:error, :too_large}
      assert MatchSpec.parse("'" <> String.duplicate("ż", 2_048) <> "'") == {:error, :too_large}
    end
  end

  describe "parse_fun/3" do
    test "returns an error when folded constants outgrow the parsing process" do
      for {language, head, shift} <- [
            {:erlang, "fun({X}) ->", "1 bsl 4000000"},
            {:elixir, "fn {x} ->", "1 <<< 4000000"}
          ] do
        source = "#{head} [#{Enum.map_join(1..20, ", ", fn _ -> shift end)}] end"

        assert MatchSpec.parse_fun(source, language, :table) == {:error, :limit_exceeded}, source
      end
    end

    test "turns the parameter and a guard into a clause" do
      trace = {:ok, [{[:"$1", :_], [{:>, :"$1", 10}], [true]}]}
      table = {:ok, [{{:"$1", :"$2"}, [{:>, :"$2", 1}], [:"$1"]}]}

      for {language, type, source, result} <- [
            {:erlang, :trace, "fun([A, _]) when A > 10 -> true end", trace},
            {:elixir, :trace, "fn [a, _] when a > 10 -> true end", trace},
            {:erlang, :table, "fun({K, V}) when V > 1 -> K end", table},
            {:elixir, :table, "fn {k, v} when v > 1 -> k end", table}
          ] do
        assert MatchSpec.parse_fun(source, language, type) == result, source
      end
    end

    test "binds the whole argument list to a variable" do
      for {language, source} <- [
            erlang: "fun(Args) when length(Args) > 1 -> true end",
            elixir: "fn args when length(args) > 1 -> true end"
          ] do
        assert MatchSpec.parse_fun(source, language, :trace) ==
                 {:ok, [{:"$1", [{:>, {:length, :"$1"}, 1}], [true]}]},
               source
      end
    end

    test "matches literals, lists, maps and repeated variables" do
      for {language, source} <- [
            erlang: ~S'fun({K, K, [1 | T], #{k := V}, <<"b">>, -2.5, ok, nil}) -> V end',
            elixir: ~S'fn {k, k, [1 | t], %{k: v}, "b", -2.5, :ok, nil} -> v end'
          ] do
        assert MatchSpec.parse_fun(source, language, :table) ==
                 {:ok,
                  [{{:"$1", :"$1", [1 | :"$2"], %{k: :"$3"}, "b", -2.5, :ok, nil}, [], [:"$3"]}]},
               source
      end
    end

    test "refuses anything but one parameter of the type's shape" do
      messages = %{
        trace: "dbg:fun2ms requires fun with single variable or list parameter",
        table: "ets:fun2ms requires fun with single variable or tuple parameter"
      }

      for {language, type, source} <- [
            {:erlang, :trace, "fun({K, V}) -> K end"},
            {:elixir, :trace, "fn {k, v} -> k end"},
            {:elixir, :trace, "fn %{k: v} -> v end"},
            {:elixir, :trace, "fn :atom -> 1 end"},
            {:elixir, :trace, "fn a, b -> a end"},
            {:elixir, :trace, "fn a, b when a > b -> a end"},
            {:elixir, :trace, "fn -> 1 end"},
            {:erlang, :table, "fun([K]) -> K end"},
            {:erlang, :table, "fun(A, B) -> A end"},
            {:erlang, :table, "fun() -> ok end"},
            {:elixir, :table, "fn [k] -> k end"}
          ] do
        assert MatchSpec.parse_fun(source, language, type) ==
                 {:error, {:unsupported, messages[type]}},
               source
      end
    end

    test "refuses a variable the head does not bind" do
      for {language, source, message} <- [
            {:erlang, "fun({K}) when K > X -> K end", "the variable X is unbound"},
            {:elixir, "fn {x} when x > y -> x end", ~S(undefined variable "y")},
            {:elixir, "fn {x} -> y end", ~S(undefined variable "y")},
            {:elixir, "fn {x} -> _ end", "invalid use of _"}
          ] do
        assert {:error, {:unsupported, error}} = MatchSpec.parse_fun(source, language, :table),
               source

        assert error =~ message
      end
    end

    test "refuses a reserved atom in the head" do
      for {language, source} <- [
            erlang: "fun({X, '$1'}) -> X end",
            elixir: ~S|fn {x, :"$1"} -> x end|
          ] do
        assert {:error, {:unsupported, message}} = MatchSpec.parse_fun(source, language, :table),
               source

        assert message =~ "'$1'"
      end
    end

    test "refuses a segment too big before building it" do
      for {language, source} <- [
            erlang: "fun({X}) when X == <<0:99999999999999>> -> X end",
            elixir: "fn {x} when x == <<0::99999999999999>> -> x end"
          ] do
        assert MatchSpec.parse_fun(source, language, :table) ==
                 {:error,
                  {:syntax, "binary segments must have an integer size of at most 524288 bits"}},
               source
      end
    end

    test "refuses anything but one fun" do
      for {language, message, sources} <- [
            {:erlang, "expected one fun ... end",
             [
               "[{'_', [], []}]",
               "ok",
               "fun(X) -> X end, fun(Y) -> Y end",
               "fun F({X}) -> X end",
               "fun erlang:halt/0"
             ]},
            {:elixir, "expected one fn ... end",
             ["[{:_, [], []}]", "x", ":ok", "&(&1)", "fn {x} -> x end; fn {y} -> y end"]}
          ],
          source <- sources do
        assert MatchSpec.parse_fun(source, language, :table) == {:error, {:syntax, message}},
               source
      end
    end

    test "reports syntax errors" do
      for {language, source} <- [
            erlang: "fun(X) -> X",
            erlang: "fun(X) X end",
            elixir: "fn x -> x",
            elixir: "fn x x end",
            elixir: "1 +",
            elixir: "",
            elixir: "fn {x} -> x end."
          ] do
        assert {:error, {:syntax, message}} = MatchSpec.parse_fun(source, language, :table),
               inspect(source)

        assert is_binary(message)
      end
    end
  end

  describe "parse_fun/3 with :erlang and :trace" do
    test "keeps trace actions in the body" do
      assert parse_erlang(
               "fun([A]) when A > 10 -> return_trace(), message(A); (_) -> true end",
               :trace
             ) ==
               {:ok,
                [
                  {[:"$1"], [{:>, :"$1", 10}], [{:return_trace}, {:message, :"$1"}]},
                  {:_, [], [true]}
                ]}
    end
  end

  describe "parse_fun/3 with :erlang and :table" do
    test "splits guard sequences into clauses and keeps guard lists" do
      assert parse_erlang("fun({K, V}) when is_integer(V), V > 1; K == a -> {K, V} end", :table) ==
               {:ok,
                [
                  {{:"$1", :"$2"}, [{:is_integer, :"$2"}, {:>, :"$2", 1}], [{{:"$1", :"$2"}}]},
                  {{:"$1", :"$2"}, [{:==, :"$1", :a}], [{{:"$1", :"$2"}}]}
                ]}
    end

    test "keeps remote guard calls, folds shifts and builds sized segments" do
      source = "fun({X}) when erlang:is_atom(X); X > 1 bsl 64; X == <<1:16>> -> X end"

      assert parse_erlang(source, :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:is_atom, :"$1"}], [:"$1"]},
                  {{:"$1"}, [{:>, :"$1", 18_446_744_073_709_551_616}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", <<0, 1>>}], [:"$1"]}
                ]}
    end

    test "wraps constant tuples and reserved atoms in the body" do
      assert parse_erlang("fun({K}) when K == {a, b} -> '$1' end", :table) ==
               {:ok, [{{:"$1"}, [{:==, :"$1", {{:a, :b}}}], [const: :"$1"]}]}
    end
  end

  describe "parse_fun/3 with :erlang errors" do
    test "refuses what ms_transform cannot translate" do
      for {source, type} <- [
            {"fun({X}) -> #r{} end", :table},
            {"fun({X}) when X = 1 -> X end", :table},
            {"fun({X}) -> list_to_atom(X) end", :table},
            {"fun({X}) when tuple_size(X) > 1 -> X end", :table},
            {"fun({X}) when is_boolean(X) -> X end", :table},
            {"fun([X]) -> case X of _ -> X end end", :trace},
            {~S|fun(_) -> os:cmd("id") end|, :trace}
          ] do
        assert {:error, {:unsupported, message}} = parse_erlang(source, type), source
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
        assert parse_erlang(source, type) ==
                 {:error, {:unsupported, "the fun cannot be turned into a match spec"}},
               source
      end
    end

    test "refuses the ! operator, which ms_transform would send" do
      name = :"probe_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert parse_erlang("fun([X]) when X == (#{name} ! leaked) -> true end", :trace) ==
               {:error, {:syntax, "the ! operator is not allowed"}}

      refute_received :leaked
    end

    test "keeps a ! that is an atom, a string or a char" do
      assert parse_erlang(~S|fun({X}) when X == '!'; X == "!"; X == $! -> X end|, :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:==, :"$1", :!}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", ~c"!"}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", ?!}], [:"$1"]}
                ]}
    end
  end

  describe "parse_fun/3 with :elixir and :trace" do
    test "translates every clause" do
      assert parse_elixir("fn [a] when a > 1 -> true\n _ -> false end", :trace) ==
               {:ok, [{[:"$1"], [{:>, :"$1", 1}], [true]}, {:_, [], [false]}]}
    end
  end

  describe "parse_fun/3 with :elixir and :table" do
    test "matches anything with _ and binds _name like any variable" do
      assert parse_elixir("fn {_, _a, _a, x} -> x end", :table) ==
               {:ok, [{{:_, :"$1", :"$1", :"$2"}, [], [:"$2"]}]}

      assert parse_elixir("fn {_a, _a} -> true end", :table) ==
               MatchSpec.parse_fun("fun({_A, _A}) -> true end", :erlang, :table)
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
        assert parse_elixir("fn {x} when x #{elixir} 1 -> x end", :table) ==
                 {:ok, [{{:"$1"}, [{erlang, :"$1", 1}], [:"$1"]}]},
               elixir
      end
    end

    test "translates and, or, not and type checks" do
      source = "fn {x, y} when is_integer(x) and (y == :a or not is_atom(y)) -> x end"

      assert parse_elixir(source, :table) ==
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
        assert parse_elixir("fn {x} when #{elixir} > 0 -> #{elixir} end", :table) ==
                 {:ok, [{{:"$1"}, [{:>, erlang, 0}], [erlang]}]},
               elixir
      end
    end

    test "folds constant arithmetic, as the Erlang fun does" do
      assert parse_elixir("fn {x} when x > 1 + 2 * -3 -> x end", :table) ==
               {:ok, [{{:"$1"}, [{:>, :"$1", -5}], [:"$1"]}]}
    end

    test "reads map fields and expands in, ranges and is_struct" do
      assert parse_elixir("fn {x} when x.key > 1 and x.a.b == 2 -> x end", :table) ==
               MatchSpec.parse_fun(
                 "fun({X}) when map_get(key, X) > 1 andalso map_get(b, map_get(a, X)) == 2 -> X end",
                 :erlang,
                 :table
               )

      source = "fn {x} when x in [:a, :b] or x in 1..3 or is_struct(x, URI) -> x end"
      assert {:ok, spec} = parse_elixir(source, :table)
      assert MatchSpec.check_compiles(spec, :table) == :ok
    end

    test "gives each extra when its own clause" do
      assert parse_elixir("fn {x} when x > 1 when x == :a -> x end", :table) ==
               {:ok,
                [
                  {{:"$1"}, [{:>, :"$1", 1}], [:"$1"]},
                  {{:"$1"}, [{:==, :"$1", :a}], [:"$1"]}
                ]}
    end

    test "builds tuples and lists and wraps reserved atoms" do
      assert parse_elixir(~S|fn {x} when x == {:a, [1, "b"]} or x == :"$1" -> x end|, :table) ==
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
      assert parse_elixir("fn [a] -> a\n true end", :trace) ==
               {:ok, [{[:"$1"], [], [:"$1", true]}]}
    end

    test "builds tuples, n-tuples, lists and maps" do
      assert parse_elixir("fn {k, v} -> {k, [v | k], {k, v, 1}, %{key: v}} end", :table) ==
               {:ok,
                [
                  {{:"$1", :"$2"}, [],
                   [{{:"$1", [:"$2" | :"$1"], {{:"$1", :"$2", 1}}, %{key: :"$2"}}}]}
                ]}
    end
  end

  describe "parse_fun/3 with :elixir errors" do
    test "refuses the forms whose expansion would run code on this node" do
      for source <- [
            ~S|fn {x} -> System.cmd("id", []) end|,
            "fn {x} -> Kernel.div(x, 2) end",
            "fn {x} -> Kernel.use(GenServer) end",
            ~S|fn {x} -> :"Elixir.Kernel".use(GenServer) end|,
            "fn {x} -> MyApp.Repo.config() end",
            "fn {x} -> Elixir.System.halt() end",
            "fn {x} -> :lists.reverse(x) end",
            "fn {x} -> import String\n upcase(x) end",
            "fn {x} -> require Logger\n Logger.info(x) end",
            "fn {x} -> %URI{} end",
            "fn {%URI{host: h}} -> h end",
            ~S|fn {x} -> "a#{x}" end|,
            "fn {x} -> &IO.puts/1 end"
          ] do
        assert {:error, {:unsupported, message}} = parse_elixir(source, :table), source
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
            "fn {a} -> 1\n a, b -> 2 end",
            "fn {x} -> :erlang.apply(:erlang, :halt, []) end",
            "fn {x} -> x |> elem(0) end",
            "fn {x} -> x && 1 end",
            "fn {x} -> !x end",
            ~S|fn {x} -> x <> "a" end|,
            "fn {x} -> to_string(x) end",
            "fn {x} -> ~s(a) end",
            "fn {x} -> quote do: x end",
            "fn {x} -> for y <- x, do: y end",
            "fn {x} -> receive do\n _ -> 1 end end"
          ] do
        assert {:error, {:unsupported, message}} = parse_elixir(source, :table), source
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
        assert {:error, {:unsupported, _message}} = parse_elixir(source, :table), source
      end

      refute_received :leaked
    end
  end

  describe "parse_fun/3 with :elixir fun2ms features" do
    test "binds the whole parameter with a top-level =" do
      for {source, type} <- [
            {"fn {k, _} = row -> {k, row} end", :table},
            {"fn row = {k, _} -> {k, row} end", :table}
          ] do
        assert parse_elixir(source, type) == {:ok, [{{:"$1", :_}, [], [{{:"$1", :"$_"}}]}]},
               source
      end

      assert parse_elixir("fn [a] = args -> message(args) end", :trace) ==
               {:ok, [{[:"$1"], [], [{:message, :"$_"}]}]}
    end

    test "refuses = anywhere but the top of the head, or with a name bound twice" do
      for source <- ["fn {a = b} -> a end", "fn {a, _} = a -> a end", "fn {a} = {b} -> a end"] do
        assert {:error, {:unsupported, _message}} = parse_elixir(source, :table), source
      end
    end

    test "translates Elixir names to their Erlang forms" do
      for {elixir, erlang} <- [
            {"elem(x, 0)", {:element, 1, :"$1"}},
            {"elem(x, x)", {:element, {:+, :"$1", 1}, :"$1"}},
            {"is_map_key(x, :k)", {:is_map_key, :k, :"$1"}},
            {"is_nil(x)", {:==, :"$1", nil}},
            {":erlang.element(1, x)", {:element, 1, :"$1"}},
            {":erlang.xor(x, true)", {:xor, :"$1", true}},
            {"x &&& 1", {:band, :"$1", 1}},
            {"band(x, 1)", {:band, :"$1", 1}},
            {"~~~x", {:bnot, :"$1"}},
            {"+x", {:+, :"$1"}},
            {"object()", :"$_"},
            {"bindings()", :"$*"}
          ] do
        assert parse_elixir("fn {x} -> #{elixir} end", :table) == {:ok, [{{:"$1"}, [], [erlang]}]},
               elixir
      end
    end

    test "keeps trace actions in a body and refuses them in a guard" do
      assert parse_elixir("fn [a] -> return_trace(); message(caller()); display(a) end", :trace) ==
               {:ok, [{[:"$1"], [], [{:return_trace}, {:message, {:caller}}, {:display, :"$1"}]}]}

      assert {:error, {:unsupported, _message}} =
               parse_elixir("fn [a] when message(a) -> true end", :trace)
    end

    test "leaves an action in a table body for check_compiles/2 to refuse, as ms_transform does" do
      assert {:ok, spec} = parse_elixir("fn {a} -> return_trace() end", :table)

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
        assert parse_elixir("fn {x} when x == #{elixir} -> x end", :table) ==
                 {:ok, [{{:"$1"}, [{:==, :"$1", binary}], [:"$1"]}]},
               elixir
      end
    end

    test "refuses bit syntax that is not a literal" do
      assert {:error, {:unsupported, _}} = parse_elixir("fn {x} -> <<x::8>> end", :table)
      assert {:error, {:unsupported, _}} = parse_elixir("fn {x} -> <<1.5::8>> end", :table)
    end
  end

  test "matches what the Erlang fun gives" do
    for {elixir, erlang, type} <- [
          {"fn [a] -> message(get_tcw())\n is_seq_trace() end",
           "fun([A]) -> message(get_tcw()), is_seq_trace() end", :trace},
          {"fn [a] -> current_stacktrace(2) end", "fun([A]) -> current_stacktrace(2) end",
           :trace},
          {"fn [MyApp.Repo, :all, [q | _]] -> message(q) end",
           "fun(['Elixir.MyApp.Repo', all, [Q | _]]) -> message(Q) end", :trace},
          {"fn {a} -> {abs(a), hd(a), tl(a), length(a), round(a), trunc(a), float(a), max(a, 1), min(a, 2), node(), node(a), self(), byte_size(a), bit_size(a), map_size(a), binary_part(a, 0, 1)} end",
           "fun({A}) -> {abs(A), hd(A), tl(A), length(A), round(A), trunc(A), float(A), max(A, 1), min(A, 2), node(), node(A), self(), byte_size(A), bit_size(A), map_size(A), binary_part(A, 0, 1)} end",
           :table},
          {"fn {a} -> {bxor(a, 1), bnot(a), bsl(a, 2), bsr(a, 1), a <<< 1, a >>> 1, a ||| 2} end",
           "fun({A}) -> {A bxor 1, bnot A, A bsl 2, A bsr 1, A bsl 1, A bsr 1, A bor 2} end",
           :table}
        ] do
      assert parse_elixir(elixir, type) == MatchSpec.parse_fun(erlang, :erlang, type), elixir
    end
  end

  describe "check_shape/1" do
    test "accepts one or more clauses" do
      assert MatchSpec.check_shape([{:_, [], []}]) == :ok
      assert MatchSpec.check_shape([{[:"$1"], [{:>, :"$1", 1}], [true]}, {:_, [], []}]) == :ok
    end

    test "rejects a term that is not a spec" do
      for term <- @not_specs do
        assert MatchSpec.check_shape(term) == {:error, :invalid_shape}, inspect(term)
      end
    end
  end

  describe "check_clauses/2" do
    test "accepts up to max clauses" do
      assert MatchSpec.check_clauses([{:_, [], []}], 1) == :ok
      assert MatchSpec.check_clauses(List.duplicate({:_, [], []}, 10), 10) == :ok
    end

    test "refuses more than max clauses" do
      assert MatchSpec.check_clauses(List.duplicate({:_, [], []}, 2), 1) ==
               {:error, {:too_many_clauses, 1}}

      assert MatchSpec.check_clauses(List.duplicate({:_, [], []}, 11), 10) ==
               {:error, {:too_many_clauses, 10}}
    end
  end

  describe "check_actions/2" do
    @refused [:return_trace, :exception_trace, :enable_trace]

    test "accepts a spec without refused actions" do
      spec = [{[:"$1"], [{:>, :"$1", 1}], [{:message, :"$1"}, true]}, {:_, [], []}]

      assert MatchSpec.check_actions(spec, @refused) == :ok
      assert MatchSpec.check_actions([{:_, [], [{:return_trace}]}], []) == :ok
    end

    test "refuses an action at any depth of the guards or body" do
      for {spec, action} <- [
            {[{:_, [], [{:return_trace}]}], :return_trace},
            {[{:_, [], [true]}, {:_, [], [{:exception_trace}]}], :exception_trace},
            {[{:_, [], [{:message, {{:ok, {:enable_trace, :send}}}}]}], :enable_trace},
            {[{:_, [{:is_list, {:return_trace}}], []}], :return_trace},
            {[{:_, [], [{:message, {:const, %{key: {:exception_trace}}}}]}], :exception_trace},
            {[{:_, [], [{:message, [:a | {:return_trace}]}]}], :return_trace},
            {[{:_, [], [{:message, %{{:enable_trace, :send} => 1}}]}], :enable_trace}
          ] do
        assert MatchSpec.check_actions(spec, @refused) == {:error, {:refused_action, action}},
               inspect(spec)
      end
    end

    test "reports the first refused action" do
      spec = [{:_, [], [{:exception_trace}, {:return_trace}]}]

      assert MatchSpec.check_actions(spec, @refused) ==
               {:error, {:refused_action, :exception_trace}}
    end

    test "ignores the head, where a tuple is a pattern" do
      assert MatchSpec.check_actions([{[{:return_trace}], [], []}], @refused) == :ok
    end

    test "ignores a refused name that is not the first element of a tuple" do
      body = [:return_trace, {}, {"return_trace"}, {:message, :return_trace}]

      assert MatchSpec.check_actions([{:_, [:return_trace], body}], @refused) == :ok
    end
  end

  describe "check_compiles/2" do
    test "accepts specs that compile for their type" do
      assert MatchSpec.check_compiles([{{:"$1", :"$2"}, [{:>, :"$2", 10}], [:"$1"]}], :table) ==
               :ok

      assert MatchSpec.check_compiles([{{:_, %{k: :"$1"}}, [], [:"$_"]}], :table) == :ok

      assert MatchSpec.check_compiles(
               [{[:"$1", :_], [{:is_binary, :"$1"}], [{:message, :"$1"}, {:return_trace}]}],
               :trace
             ) == :ok
    end

    test "compiles a body without running it" do
      # Run by match_spec_test/3, `{enable_trace, send}` segfaults the VM.
      assert MatchSpec.check_compiles([{:_, [], [{:enable_trace, :send}]}], :trace) == :ok
    end

    test "reports what does not compile" do
      for {spec, type} <- [
            {[{:_, [{:no_such_guard, :"$1"}], []}], :trace},
            {[{:_, [], [:"$7"]}], :trace},
            {[{:_, [], [{:no_such_action, 1}]}], :trace},
            {[{:_, [], [{:message, 1}]}], :table},
            {[{"head", [], []}], :trace},
            {[{:_, [], []}, {:_, [{:no_such_guard}], []}], :trace}
          ] do
        assert {:error, {:compile, [_ | _] = errors}} = MatchSpec.check_compiles(spec, type),
               inspect(spec)

        assert Enum.all?(errors, &is_binary/1)
      end
    end

    test "reports every error of a clause" do
      assert MatchSpec.check_compiles([{:_, [:"$1"], []}], :table) ==
               {:error,
                {:compile, ["Variable $1 is unbound.", "Body clause does not return anything."]}}
    end
  end

  describe "check_size/2" do
    test "accepts up to max_bytes in the external term format" do
      encoded = MatchSpec.encode([{:_, [], [:ok]}])
      size = :erlang.external_size(encoded)

      assert MatchSpec.check_size(encoded, size) == :ok
      assert MatchSpec.check_size(encoded, size - 1) == {:error, {:too_large, size - 1}}
    end

    test "measures a term that is not a spec" do
      assert MatchSpec.check_size(:ok, 1) == {:error, {:too_large, 1}}
    end
  end

  test "checks compose over a spec from either parser" do
    term = ~S([{['$1', '_'], [{'>', '$1', 10}], [{message, '$1'}]}, {'_', [], [true]}])
    fun = "fun([A, _]) when A > 10 -> message(A); (_) -> true end"

    assert {:ok, spec} = MatchSpec.parse(term)
    assert MatchSpec.parse_fun(fun, :erlang, :trace) == {:ok, spec}
    assert MatchSpec.check_clauses(spec, 10) == :ok
    assert MatchSpec.check_actions(spec, [:return_trace]) == :ok
    assert MatchSpec.check_compiles(spec, :trace) == :ok
    assert MatchSpec.check_size(MatchSpec.encode(spec), 65_536) == :ok
  end

  describe "encode/1" do
    test "tags constant atoms in the head, guards and body" do
      spec = [{[:"$1", :active], [{:==, :"$1", :ok}], [{:message, true}]}]

      assert MatchSpec.encode(spec) == [
               {[:"$1", tag(:active)], [{tag(:==), :"$1", tag(:ok)}],
                [{tag(:message), tag(true)}]}
             ]
    end

    test "leaves match variables as they are" do
      for variable <- [:_, :"$_", :"$$", :"$0", :"$1", :"$123", :"$1000"] do
        spec = [{%{variable => variable}, [], [variable]}]

        assert MatchSpec.encode(spec) == spec
      end
    end

    test "tags atoms that only look like variables, and variables past $1000" do
      for atom <-
            [:"", :"$", :"$abc", :"$1a", :"$-1", :"$+1", :__, :"$__", :"$_1", :"$$$"] ++
              [:"$007", :"$01", :"$1001", :"$900000008834"] do
        assert MatchSpec.encode([{atom, [], []}]) == [{tag(atom), [], []}], inspect(atom)
      end
    end

    test "encodes struct-shaped maps as plain maps without running their protocols" do
      stream = %{__struct__: File.Stream, path: "missing", raw: true}
      range = %{__struct__: Range, first: 1, last: 3, step: 1}
      set = %{__struct__: MapSet, map: %{x: []}}

      assert MatchSpec.encode(stream) == %{
               tag(:__struct__) => tag(File.Stream),
               tag(:path) => "missing",
               tag(:raw) => tag(true)
             }

      assert MatchSpec.encode(range) == %{
               tag(:__struct__) => tag(Range),
               tag(:first) => 1,
               tag(:last) => 3,
               tag(:step) => 1
             }

      assert MatchSpec.encode(set) == %{
               tag(:__struct__) => tag(MapSet),
               tag(:map) => %{tag(:x) => []}
             }
    end

    test "tags atoms inside maps, nested tuples and improper lists" do
      spec = [{{%{key: [:a | :b]}}, [], [{:const, {{:c}}}]}]

      assert MatchSpec.encode(spec) == [
               {{%{tag(:key) => [tag(:a) | tag(:b)]}}, [], [{tag(:const), {{tag(:c)}}}]}
             ]
    end

    test "leaves numbers, binaries and empty terms alone" do
      spec = [{[1, -2.5, "atom", {}, %{}], [], [~c"ab", []]}]

      assert MatchSpec.encode(spec) == spec
    end

    test "tags the tag atom itself, so a literal tag tuple survives" do
      spec = [{:_, [], [{:const, {@tag_atom, "x"}}]}]

      assert MatchSpec.encode(spec) == [
               {:_, [], [{tag(:const), {tag(@tag_atom), "x"}}]}
             ]
    end
  end

  describe "format_error/1" do
    test "describes every reason" do
      for {reason, message} <- [
            {:too_large, "longer than 4096 bytes"},
            {:atom_table_full, "atom table exhausted"},
            {:limit_exceeded, "building it needs more than 8 MiB or 2000 ms"},
            {{:syntax, "syntax error before: ')'"}, "syntax error before: ')'"},
            {{:unsupported, "`%URI{}` is not supported"}, "`%URI{}` is not supported"},
            {:invalid_shape, "expected a list of {head, guards, body} clauses"},
            {{:too_many_clauses, 1}, "expected one {head, guards, body} clause"},
            {{:too_many_clauses, 10}, "expected at most 10 clauses"},
            {{:too_large, 65_536}, "encodes to more than 65536 bytes"},
            {{:refused_action, :return_trace}, "the return_trace action is not allowed"},
            {{:compile, ["Variable $7 is unbound.", "Bad."]}, "Variable $7 is unbound. Bad."},
            {{:unknown_atom, "nope"}, "atom 'nope' does not exist on the node"}
          ] do
        assert MatchSpec.format_error(reason) == message
      end
    end
  end

  defp parse_erlang(source, type), do: MatchSpec.parse_fun(source, :erlang, type)
  defp parse_elixir(source, type), do: MatchSpec.parse_fun(source, :elixir, type)
  defp tag(atom), do: {@tag_atom, Atom.to_string(atom)}
end
