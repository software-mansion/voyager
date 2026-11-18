defmodule Voyager.Services.Tracer.MatchSpecTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.MatchSpec

  @both_syntaxes [
    {"fn [a, _] when a > 10 -> true end", "fun([A, _]) when A > 10 -> true end.", 2,
     [{[:"$1", :_], [{:>, :"$1", 10}], []}]},
    {"fn args -> true end", "fun(Args) -> true end", nil, [{:"$1", [], []}]},
    {"fn _ -> true end", "fun(_) -> true end", nil, [{:_, [], []}]},
    {"fn [a, a, _b, _b, _] -> true end", "fun([A, A, _B, _B, _]) -> true end", 5,
     [{[:"$1", :"$1", :"$2", :"$2", :_], [], []}]},
    {"fn [a, b] when is_integer(a) and (not is_nil(b)) -> true end",
     "fun([A, B]) when is_integer(A) andalso (not (B =:= nil)) -> true end", 2,
     [{[:"$1", :"$2"], [{:andalso, {:is_integer, :"$1"}, {:not, {:"=:=", :"$2", nil}}}], []}]},
    {"fn [a | _] -> true end", "fun([A | _]) -> true end", 2, [{[:"$1" | :_], [], []}]},
    {~s(fn [:ok, "s", ~c"ab", 1.5, -2, ?a, nil, Foo] -> true end),
     ~s(fun([ok, <<"s">>, "ab", 1.5, -2, $a, nil, 'Elixir.Foo']\) -> true end), 8,
     [{[:ok, "s", ~c"ab", 1.5, -2, ?a, nil, Foo], [], []}]},
    {"fn [[h | t], {x, y}, {1, 2, 3}, {}] -> true end",
     "fun([[H | T], {X, Y}, {1, 2, 3}, {}]) -> true end", 4,
     [{[[:"$1" | :"$2"], {:"$3", :"$4"}, {1, 2, 3}, {}], [], []}]},
    {~s(fn [%{"k" => 1, id: id}] -> true end), ~s(fun([\#{<<"k">> := 1, id := Id}]\) -> true end),
     1, [{[%{:id => :"$1", "k" => 1}], [], []}]},
    {~s(fn [~c"ab" ++ rest, [1, x] ++ _] -> true end),
     ~s(fun(["ab" ++ Rest, [1, X] ++ _]\) -> true end), 2,
     [{[[?a, ?b | :"$1"], [1, :"$2" | :_]], [], []}]},
    {"fn [a] -> true; [b, _] -> true end", "fun([A]) -> true; ([B, _]) -> true end", nil,
     [{[:"$1"], [], []}, {[:"$1", :_], [], []}]},
    {"fn [a] when a > 1 when a == :x -> true end", "fun([A]) when A > 1; A == x -> true end", 1,
     [{[:"$1"], [{:>, :"$1", 1}], []}, {[:"$1"], [{:==, :"$1", :x}], []}]},
    {"fn [a, b] when a === b and a !== 1 or not (a <= b) -> true end",
     "fun([A, B]) when A =:= B andalso A =/= 1 orelse not (A =< B) -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:andalso, {:"=:=", :"$1", :"$2"}, {:"=/=", :"$1", 1}},
           {:not, {:"=<", :"$1", :"$2"}}}
        ], []}
     ]},
    {"fn [a, b] when -a * 2 / 3 - 1 + div(a, 2) >= rem(b, 2) and a != b -> true end",
     "fun([A, B]) when -A * 2 / 3 - 1 + A div 2 >= B rem 2 andalso A /= B -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:andalso,
           {:>=, {:+, {:-, {:/, {:*, {:-, :"$1"}, 2}, 3}, 1}, {:div, :"$1", 2}},
            {:rem, :"$2", 2}}, {:"/=", :"$1", :"$2"}}
        ], []}
     ]},
    {"fn [a] when (a &&& 3 ||| 4) <<< 1 >>> 2 == ~~~a -> true end",
     "fun([A]) when (A band 3 bor 4) bsl 1 bsr 2 == bnot A -> true end", 1,
     [
       {[:"$1"], [{:==, {:bsr, {:bsl, {:bor, {:band, :"$1", 3}, 4}, 1}, 2}, {:bnot, :"$1"}}], []}
     ]},
    {"fn [a, b] when a == {:ok, b} or (a == [1, b | b] or a == {b, 2, 3}) -> true end",
     "fun([A, B]) when A == {ok, B} orelse A == [1, B | B] orelse A == {B, 2, 3} -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:==, :"$1", {{:ok, :"$2"}}},
           {:orelse, {:==, :"$1", [1, :"$2" | :"$2"]}, {:==, :"$1", {{:"$2", 2, 3}}}}}
        ], []}
     ]},
    {"fn [a] when a == %{k: a} -> true end", "fun([A]) when A == \#{k => A} -> true end", 1,
     [{[:"$1"], [{:==, :"$1", %{k: :"$1"}}], []}]},
    {"fn [a] when a == self() and node(a) == node() -> true end",
     "fun([A]) when A == self() andalso node(A) == node() -> true end", 1,
     [{[:"$1"], [{:andalso, {:==, :"$1", {:self}}, {:==, {:node, :"$1"}, {:node}}}], []}]}
  ]

  @elixir_only [
    {"fn [%MyApp.User{id: id}, :ets, Elixir.Foo] -> true end", 3,
     [{[%{__struct__: MyApp.User, id: :"$1"}, :ets, Foo], [], []}]},
    {"fn [a: 1, b: b] -> true end", 2, [{[{:a, 1}, {:b, :"$1"}], [], []}]},
    {~S|fn [~C(a\n), ~c"a\n"] -> true end|, 2, [{[[?a, ?\\, ?n], [?a, ?\n]], [], []}]},
    {"fn [a] when a == %MyApp.User{id: 1} -> true end", 1,
     [{[:"$1"], [{:==, :"$1", %{__struct__: MyApp.User, id: 1}}], []}]},
    {"fn [a, i] when is_nil(a) or elem(a, 0) == elem(a, i) -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:"=:=", :"$1", nil},
           {:==, {:element, 1, :"$1"}, {:element, {:+, :"$2", 1}, :"$1"}}}
        ], []}
     ]},
    {"fn [m] when is_map_key(m, :id) and map_get(m, :id) > 0 -> true end", 1,
     [{[:"$1"], [{:andalso, {:is_map_key, :id, :"$1"}, {:>, {:map_get, :id, :"$1"}, 0}}], []}]},
    {"fn [a] when a in [1, :b] or a in [] -> true end", 1,
     [{[:"$1"], [{:orelse, {:orelse, {:"=:=", :"$1", 1}, {:"=:=", :"$1", :b}}, false}], []}]},
    {"fn [a] when a not in 1..10 -> true end", 1,
     [
       {[:"$1"],
        [
          {:not,
           {:andalso, {:is_integer, :"$1"}, {:andalso, {:>=, :"$1", 1}, {:"=<", :"$1", 10}}}}
        ], []}
     ]},
    {"fn [s] when is_struct(s) or is_struct(s, MyApp.User) -> true end", 1,
     [
       {[:"$1"],
        [
          {:orelse,
           {:andalso, {:is_map, :"$1"},
            {:andalso, {:is_map_key, :__struct__, :"$1"},
             {:is_atom, {:map_get, :__struct__, :"$1"}}}},
           {:andalso, {:is_map, :"$1"},
            {:andalso, {:is_map_key, :__struct__, :"$1"},
             {:"=:=", {:map_get, :__struct__, :"$1"}, MyApp.User}}}}
        ], []}
     ]}
  ]

  @erlang_only [
    {"fun(All = [A, _]) when length(All) > A -> true end", 2,
     [{[:"$1", :_], [{:>, {:length, :"$_"}, :"$1"}], []}]},
    {"fun([A]) when A > 1, A < 5 -> true end", 1,
     [{[:"$1"], [{:>, :"$1", 1}, {:<, :"$1", 5}], []}]},
    {"fun([A]) when A == <<1, \"b\">> -> true end", 1, [{[:"$1"], [{:==, :"$1", <<1, ?b>>}], []}]}
  ]

  @matches [
    {"fn [a] when a in [1, :b] -> true end", [[1], [:b]], [[2], [1.0], ["b"]]},
    {"fn [a] when a in 1..3 -> true end", [[1], [3]], [[0], [4], [2.0], [:a]]},
    {"fn [a] when a not in 1..3 -> true end", [[0], [:a]], [[2]]},
    {"fn [t] when elem(t, 0) == :ok -> true end", [[{:ok, 1}]], [[{:error, :ok}], [:ok]]},
    {"fn [t, i] when elem(t, i) == :ok -> true end", [[{1, :ok}, 1]], [[{1, :ok}, 0]]},
    {"fn [m] when is_map_key(m, :id) and map_get(m, :id) > 0 -> true end", [[%{id: 1}]],
     [[%{id: 0}], [%{}], [1]]},
    {"fn [s] when is_struct(s) -> true end", [[~D[2024-01-01]]],
     [[%{}], [%{__struct__: 1}], [1]]},
    {"fn [s] when is_struct(s, Date) -> true end", [[~D[2024-01-01]]], [[~T[00:00:00]], [%{}]]},
    {"fn [s] when not is_struct(s, Date) -> true end", [[~T[00:00:00]], [%{}], [1]],
     [[~D[2024-01-01]]]},
    {"fn [%Date{year: y}] when y > 2000 -> true end", [[~D[2024-01-01]]],
     [[~D[1999-01-01]], [%{year: 2024}]]},
    {"fn [a] when is_nil(a) -> true end", [[nil]], [[false], [[]]]},
    {"fn [a] when (a &&& 1) == 1 -> true end", [[3]], [[2], [:a]]},
    {"fn [~c\"ab\" ++ rest] when rest != [] -> true end", [[~c"abc"]],
     [[~c"ab"], [~c"xbc"], ["abc"]]},
    {"fn [a | _] when a == \"x\" -> true end", [["x"], ["x", 1, 2]], [["y"], []]},
    {"fn [a] when a > 10 when a < 0 -> true end", [[11], [-1]], [[5]]},
    {"fun([\"ab\" ++ Rest]) when Rest /= [] -> true end", [[~c"abc"]], [[~c"ab"]]},
    {"fun(All = [A, _]) when length(All) > A -> true end", [[1, :x]], [[2, :x], [1]]},
    {"fn [_a, _a] -> true end", [[1, 1]], [[1, 2]]},
    {"fn [a] when a in -2..2 -> true end", [[-2], [2]], [[-3], [3]]},
    {"fn [a, b, c | _] -> true end", [[1, 2, 3], [1, 2, 3, 4]], [[1, 2]]},
    {"fn [a] when a == [] or a == {} -> true end", [[[]], [{}]], [[[1]], [{1}]]}
  ]

  @guard_functions [
    is_atom: 1,
    is_binary: 1,
    is_bitstring: 1,
    is_boolean: 1,
    is_float: 1,
    is_function: 1,
    is_function: 2,
    is_integer: 1,
    is_list: 1,
    is_map: 1,
    is_number: 1,
    is_pid: 1,
    is_port: 1,
    is_reference: 1,
    is_tuple: 1,
    abs: 1,
    hd: 1,
    tl: 1,
    length: 1,
    map_size: 1,
    tuple_size: 1,
    byte_size: 1,
    bit_size: 1,
    round: 1,
    trunc: 1,
    ceil: 1,
    floor: 1,
    min: 2,
    max: 2,
    div: 2,
    rem: 2,
    band: 2,
    bor: 2,
    bxor: 2,
    bsl: 2,
    bsr: 2,
    bnot: 1,
    binary_part: 3,
    node: 0,
    node: 1,
    self: 0
  ]

  test "translates an fn and a fun that say the same to the same match spec" do
    for {elixir, erlang, arity, expected} <- @both_syntaxes do
      assert MatchSpec.parse(elixir, arity) == {:ok, expected}, elixir
      assert MatchSpec.parse(erlang, arity) == {:ok, expected}, erlang
    end
  end

  test "translates what only Elixir or only Erlang can write" do
    for {source, arity, expected} <- @elixir_only ++ @erlang_only do
      assert MatchSpec.parse(source, arity) == {:ok, expected}, source
    end
  end

  test "the translated match spec selects the calls the function describes" do
    for {source, matching, rejected} <- @matches do
      assert {:ok, spec} = MatchSpec.parse(source, nil)
      spec = for {head, guards, []} <- spec, do: {head, guards, [true]}

      for args <- matching,
          do: assert({:ok, true, _, _} = :erlang.match_spec_test(args, spec, :trace), source)

      for args <- rejected,
          do: assert({:ok, false, _, _} = :erlang.match_spec_test(args, spec, :trace), source)
    end
  end

  test "passes Elixir guard functions through by name" do
    for {function, arity} <- @guard_functions do
      args = Enum.take(["a", "b", "c"], arity)
      source = "fn [a, b, c] when #{function}(#{Enum.join(args, ", ")}) -> true end"
      vars = Enum.take([:"$1", :"$2", :"$3"], arity)

      assert {:ok, [{_head, [guard], []}]} = MatchSpec.parse(source, 3)
      assert guard == List.to_tuple([function | vars])
    end
  end

  test "reads leading whitespace, a trailing dot and several lines" do
    assert {:ok, [{:_, [], []}]} = MatchSpec.parse("  \n fn _ ->\n  true\nend ", nil)
    assert {:ok, [{:_, [], []}]} = MatchSpec.parse("\n fun(_) ->\n  true\nend.\n", nil)
  end

  test "refuses what a trace match spec cannot or should not hold" do
    for {source, arity, error} <- [
          {"", nil, ~r/expected an Elixir `fn \.\.\. end` or an Erlang `fun \.\.\. end`/},
          {"[{:_, [], []}]", nil, ~r/expected an Elixir `fn/},
          {<<"fn [", 255, "] -> true end">>, nil, ~r/not valid UTF-8/},
          {"fn [a] -> true", nil, ~r/missing terminator: end at line 1, column 1/},
          {"fn [a]\n when -> true end", nil, ~r/syntax error before: '->' at line 2, column 7/},
          {"fnord", nil, ~r/expected an fn/},
          {"fn [a] -> true end; File.rm(\"x\")", nil, ~r/expected an fn/},
          {"fn [a] -> true end.()", nil, ~r/expected an fn/},
          {"fn a, b -> true end", nil, ~r/takes one argument/},
          {"fn a, b when a > b -> true end", nil, ~r/takes one argument/},
          {"fn -> true end", nil, ~r/takes one argument/},
          {"fn %{} -> true end", nil, ~r/list of call arguments or a variable/},
          {"fn [a] -> true end", 2, ~r/expected 2 arguments, got 1/},
          {"fn [a | t] -> true end", nil, ~r/not a proper list/},
          {"fn [a] when b > 1 -> true end", 1, ~r/unknown variable b at line 1, column 13/},
          {"fn [a] when _ > 1 -> true end", 1, ~r/unknown variable _/},
          {"fn [a, b, c | _] -> true end", 2, ~r/expected 2 arguments, got 3/},
          {~S(fn [~c"\xFF"] -> true end), 1, ~r/invalid escape in the charlist/},
          {"fn [a] when a in 10..1 -> true end", 1, ~r/range must run between two integers/},
          {"fn [a, b] when a in 1..b -> true end", 2, ~r/range must run between two integers/},
          {"fn [a] when a in 1.5..3 -> true end", 1, ~r/range must run between two integers/},
          {"fn [a, b] when is_struct(a, b) -> true end", 2, ~r/literal module name/},
          {"fn [a] -> false end", 1, ~r/body must be `true`/},
          {"fn [a] -> a end", 1, ~r/body must be `true`/},
          {"fn [a] -> true\n true end", 1, ~r/body must be `true`/},
          {"fn [a] -> message(a) end", 1, ~r/body must be `true`/},
          {"fn [a] -> return_trace() end", 1, ~r/return_trace\(\) is not allowed/},
          {"fn [a] -> exception_trace() end", 1, ~r/exception_trace\(\) is not allowed/},
          {"fn [<<a>>] -> true end", 1, ~r/`<<>>` is not allowed/},
          {~S(fn ["a#{1}"] -> true end), 1, ~r/`<<>>` is not allowed/},
          {~S(fn [~c"a#{1}"] -> true end), 1, ~r/`sigil_c` is not allowed/},
          {"fn [~s(x)] -> true end", 1, ~r/`sigil_s` is not allowed/},
          {"fn [\"ab\" ++ rest] -> true end", 1, ~r/left side of `\+\+` must be a list/},
          {"fn [^a] -> true end", 1, ~r/`\^` is not allowed/},
          {"fn [a = 1] -> true end", 1, ~r/`=` is not allowed/},
          {"fn args = [a] -> true end", 1, ~r/`=` is not allowed/},
          {"fn [%{a => 1}] -> true end", 1, ~r/`a` is not allowed/},
          {"fn [%{m | a: 1}] -> true end", 1, ~r/`\|` is not allowed/},
          {"fn [%mod{}] -> true end", 1, ~r/`mod` is not allowed/},
          {"fn [__MODULE__] -> true end", 1, ~r/`__MODULE__` is not allowed/},
          {"fn [&is_integer/1] -> true end", 1, ~r/`&` is not allowed/},
          {"fn [a] when a = 1 -> true end", 1, ~r/`=` is not allowed in a match spec at line 1/},
          {"fn [a] when a && true -> true end", 1, ~r/`&&` is not a guard/},
          {"fn [a] when !a -> true end", 1, ~r/`!` is not a guard/},
          {"fn [a] when File.write!(a) -> true end", 1, ~r/remote calls are not allowed/},
          {"fn [a] when :erlang.length(a) > 1 -> true end", 1, ~r/remote calls are not allowed/},
          {"fn [a] when (fn -> 1 end).() -> true end", 1, ~r/remote calls are not allowed/},
          {"fn [a, b] when a in b -> true end", 2, ~r/`in` takes a literal list or a range/},
          {"fn [a] when a in [1 | a] -> true end", 1, ~r/`in` takes a literal list or a range/},
          {"fn [a] when a in 1..9//2 -> true end", 1, ~r/`in` takes a literal list or a range/},
          {"fn [a] when is_integer(a, a) -> true end", 1, ~r/is_integer\/2 does_not_exist/},
          {"fn [a] when is_record(a, :user) -> true end", 1, ~r/is_record\/2 does_not_exist/},
          {~s(fn [a] when a <> "x" == "ax" -> true end), 1, ~r/'<>'\/2 does_not_exist/},
          {"fn [a] when message(a) -> true end", 1, ~r/message/},
          {"fn [a] when enable_trace(a) -> true end", 1, ~r/enable_trace/},
          {~s(fn [:"$1"] -> true end), 1, ~r/:"\$1" is reserved/},
          {~s(fn [a] when a == :"$_" -> true end), 1, ~r/:"\$_" is reserved/},
          {~s(fn [{:"$voyager_atom", "ok"}] -> true end), 1, ~r/:"\$voyager_atom" is reserved/},
          {"fn [:_] -> true end", 1, ~r/wildcard/},
          {"function", nil, ~r/expected a fun/},
          {"fun([A]) -> 'a end", nil, ~r/unterminated atom .* at line 1/},
          {"fun([A]) -> true", nil, ~r/syntax error before: .* at line 1, column 17/},
          {"fun foo/1", nil, ~r/expected a fun/},
          {"fun F([A]) -> true end", nil, ~r/expected a fun/},
          {"fun([A]) -> true end, os:cmd(\"id\")", nil, ~r/expected a fun/},
          {"fun([A]) -> true end. os:cmd(\"id\").", nil, ~r/syntax error before: os/},
          {"fun(A, B) -> true end", nil, ~r/single variable or list parameter at line 1/},
          {"fun({A, B}) -> true end", nil, ~r/single variable or list parameter/},
          {"fun([A]) -> true end", 2, ~r/expected 2 arguments, got 1/},
          {"fun([A | T]) -> true end", nil, ~r/not a proper list/},
          {"fun([A]) when B > 1 -> true end", 1,
           ~r/variable B is unbound.* at line 1, column 15/},
          {"fun([A]) -> message(A) end", 1, ~r/body must be `true`/},
          {"fun([A]) -> ok end", 1, ~r/body must be `true`/},
          {"fun([A]) -> return_trace() end", 1, ~r/return_trace\(\) is not allowed/},
          {"fun(['$1']) -> true end", 1, ~r/:"\$1" is reserved in a match spec at line 1/},
          {"fun(['_']) -> true end", 1, ~r/:_ is reserved/},
          {"fun([A]) when A == '_' -> true end", 1, ~r/:_ is reserved/},
          {"fun([A]) when A == '$123' -> true end", 1, ~r/:"\$123" is reserved/},
          {"fun([A]) when A == <<0:800000000>> -> true end", 1, ~r/bit syntax sizes and types/},
          {"fun([A]) when A == <<1/bogus>> -> true end", 1, ~r/bit syntax sizes and types/},
          {"fun([1 + 1]) -> true end", 1, ~r/cannot be translated/},
          {"fun([-A]) -> true end", 1, ~r/cannot be translated/},
          {"fun([foo()]) -> true end", 1, ~r/cannot be translated/},
          {"fun([fun() -> ok end]) -> true end", 1, ~r/cannot be translated/},
          {"fun([[X || X <- [1]]]) -> true end", 1, ~r/cannot be translated/},
          {"fun([\#{a => 1 + 1}]) -> true end", 1, ~r/cannot be translated/},
          {"fun([A ++ \"b\"]) -> true end", 1, ~r/cannot be translated/},
          {"fun([A]) when A == <<a>> -> true end", 1, ~r/cannot be translated/},
          {"fun([A]) when A == '$foo' -> true end", 1, ~r/:"\$foo" is reserved/},
          {~s(fun([{'$voyager_atom', <<"ok">>}]\) -> true end), 1,
           ~r/:"\$voyager_atom" is reserved/},
          {"fun([A = {x, _}]) -> true end", 1, ~r/only matching \(=\) on toplevel/},
          {"fun([#r{a = 1}]) -> true end", 1, ~r/unknown record type r at line 1, column 6/},
          {"fun([A]) when is_record(A, user) -> true end", 1, ~r/unknown record type user/},
          {"fun([A]) when tuple_size(A) > 1 -> true end", 1, ~r/tuple_size\/1/},
          {"fun([A]) when lists:member(A, [1]) -> true end", 1, ~r/remote function call/},
          {"fun([A]) when [X || X <- A] == [] -> true end", 1, ~r/list comprehension/},
          {"fun([A]) when A ! 1 -> true end", 1, ~r/'!'\/2 does_not_exist/},
          {~s(fun([<<"a", X/binary>>]\) -> true end), 1, ~r/bit syntax/}
        ] do
      assert {:error, message} = MatchSpec.parse(source, arity)
      assert message =~ error, "#{inspect(source)}: #{message}"
    end
  end

  test "encodes every atom but the match spec variables for the agent" do
    assert {:ok, newline} = MatchSpec.parse(~s(fn [:"_\n"] -> true end), 1)
    assert MatchSpec.encode(newline) == [{[{:"$voyager_atom", "_\n"}], [], []}]

    spec = [
      {[:ok, %{__struct__: Date, year: :"$1"}, :_ | :"$2"],
       [{:==, :"$1", {{:error, :"$_"}}}, {:"=:=", :"$2", {:const, :"$1"}}, {:is_pid, {:self}}],
       []}
    ]

    atom = &{:"$voyager_atom", &1}

    assert MatchSpec.encode(spec) == [
             {[
                atom.("ok"),
                %{atom.("__struct__") => atom.("Elixir.Date"), atom.("year") => :"$1"},
                :_ | :"$2"
              ],
              [
                {atom.("=="), :"$1", {{atom.("error"), :"$_"}}},
                {atom.("=:="), :"$2", {atom.("const"), :"$1"}},
                {atom.("is_pid"), {atom.("self")}}
              ], []}
           ]
  end
end
