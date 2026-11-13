defmodule Voyager.Services.Tracer.MatchSpecTest do
  # async: false because the atom-count test needs no other test creating atoms meanwhile.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer.MatchSpec

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
    binary_part: 3,
    node: 0,
    node: 1,
    self: 0
  ]

  @translations [
    {"fn [a, _] when a > 10 -> true end", 2, [{[:"$1", :_], [{:>, :"$1", 10}], []}]},
    {"fn args -> true end", nil, [{:"$1", [], []}]},
    {"fn _ -> true end", nil, [{:_, [], []}]},
    {"fn [a, a, _b] -> true end", 3, [{[:"$1", :"$1", :_], [], []}]},
    {~s(fn [:ok, "s", 1.5, -2, nil, true, 'ab'] -> true end), 7,
     [{[{:"$voyager_atom", "ok"}, "s", 1.5, -2, nil, true, ~c"ab"], [], []}]},
    {"fn [[h | t], {x, y}, {1, 2, 3}] -> true end", 3,
     [{[[:"$1" | :"$2"], {:"$3", :"$4"}, {1, 2, 3}], [], []}]},
    {"fn [a | _] -> true end", 2, [{[:"$1" | :_], [], []}]},
    {~s(fn [%{"k" => 1, id: id}] -> true end), 1,
     [{[%{{:"$voyager_atom", "id"} => :"$1", "k" => 1}], [], []}]},
    {"fn [%MyApp.User{id: 1}, :ets, Elixir.Foo] -> true end", 3,
     [
       {[
          %{
            {:"$voyager_atom", "__struct__"} => {:"$voyager_atom", "Elixir.MyApp.User"},
            {:"$voyager_atom", "id"} => 1
          },
          {:"$voyager_atom", "ets"},
          {:"$voyager_atom", "Elixir.Foo"}
        ], [], []}
     ]},
    {"fn [a] when a == 1 -> true; [b] when b != 2 -> true end", 1,
     [{[:"$1"], [{:==, :"$1", 1}], []}, {[:"$1"], [{:"/=", :"$1", 2}], []}]},
    {"fn [a, b] when a === b and a !== 1 or not (a <= b) -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:andalso, {:"=:=", :"$1", :"$2"}, {:"=/=", :"$1", 1}},
           {:not, {:"=<", :"$1", :"$2"}}}
        ], []}
     ]},
    {"fn [a, b] when -a * 2 / 3 - 1 + div(a, 2) >= rem(b, 2) and a < b -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:andalso,
           {:>=, {:+, {:-, {:/, {:*, {:-, :"$1"}, 2}, 3}, 1}, {:div, :"$1", 2}},
            {:rem, :"$2", 2}}, {:<, :"$1", :"$2"}}
        ], []}
     ]},
    {"fn [a, b] when a == {:ok, b} or a == [1, b] -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:==, :"$1", {{{:"$voyager_atom", "ok"}, :"$2"}}}, {:==, :"$1", [1, :"$2"]}}
        ], []}
     ]},
    {"fn [a, i] when is_nil(a) or elem(a, 0) == elem(a, i) -> true end", 2,
     [
       {[:"$1", :"$2"],
        [
          {:orelse, {:"=:=", :"$1", nil},
           {:==, {:element, 1, :"$1"}, {:element, {:+, :"$2", 1}, :"$1"}}}
        ], []}
     ]},
    {"fn [m] when is_map_key(m, :id) and map_get(m, :id) > 0 -> true end", 1,
     [
       {[:"$1"],
        [
          {:andalso, {:is_map_key, {:"$voyager_atom", "id"}, :"$1"},
           {:>, {:map_get, {:"$voyager_atom", "id"}, :"$1"}, 0}}
        ], []}
     ]}
  ]

  test "translates heads, guards and Elixir sugar" do
    for {source, arity, expected} <- @translations do
      assert MatchSpec.parse(source, arity) == {:ok, expected}, source
    end
  end

  test "translates every allowed guard function" do
    for {function, arity} <- @guard_functions do
      args = Enum.take(["a", "b", "c"], arity)
      source = "fn [a, b, c] when #{function}(#{Enum.join(args, ", ")}) -> true end"
      vars = Enum.take([:"$1", :"$2", :"$3"], arity)

      assert {:ok, [{_head, [guard], []}]} = MatchSpec.parse(source, 3)
      assert guard == List.to_tuple([function | vars])
    end
  end

  test "every translation compiles as a trace match spec" do
    calls =
      for {function, arity} <- @guard_functions do
        "#{function}(#{Enum.join(List.duplicate("a", arity), ", ")})"
      end

    sources = [
      "fn [a] when #{Enum.join(calls, " or ")} -> true end"
      | Enum.map(@translations, &elem(&1, 0))
    ]

    for source <- sources do
      {:ok, spec} = MatchSpec.parse(source, nil)
      assert {:ok, _, _, _} = :erlang.match_spec_test([], placeholder_atoms(spec), :trace), source
    end
  end

  test "refuses what a trace match spec cannot or should not hold" do
    eleven_clauses = "fn " <> Enum.map_join(1..11, "; ", &"[#{&1}] -> true") <> " end"
    many_vars = "fn [" <> Enum.map_join(1..33, ", ", &"v#{&1}") <> "] -> true end"

    products = fn n ->
      "fn [a] when " <> Enum.map_join(1..n, " + ", fn _ -> "a * 2" end) <> " > 0 -> true end"
    end

    assert {:ok, _spec} = MatchSpec.parse(products.(16), 1)

    for {source, arity, error} <- [
          {"fn [a] -> true", nil, ~r/missing terminator: end at line 1, column 1/},
          {"fn [a] when -> true end", nil, ~r/syntax error before: '->' at line 1, column 13/},
          {"1 + 1", nil, ~r/expected an fn/},
          {"fn a, b -> true end", nil, ~r/takes one argument/},
          {"fn %{} -> true end", nil, ~r/list of call arguments or a variable/},
          {"fn [a] -> true end", 2, ~r/expected 2 arguments, got 1/},
          {"fn [a] when b > 1 -> true end", 1, ~r/unknown variable b/},
          {"fn [_a] when _a > 1 -> true end", 1, ~r/unknown variable _a/},
          {"fn [a] -> false end", 1, ~r/body must be `true`/},
          {"fn [a] -> message(a) end", 1, ~r/body must be `true`/},
          {"fn [a] -> return_trace() end", 1, ~r/return_trace\(\) is not allowed/},
          {"fn [a] -> exception_trace() end", 1, ~r/exception_trace\(\) is not allowed/},
          {"fn [<<a>>] -> true end", 1, ~r/`<<>>` is not allowed/},
          {"fn [a] when a in [1, 2] -> true end", 1, ~r/`in` is not supported/},
          {"fn [a] when a > 1 when a < 0 -> true end", 1, ~r/single `when`/},
          {"fn [^a] -> true end", 1, ~r/`\^` is not allowed/},
          {"fn [a = 1] -> true end", 1, ~r/`=` is not allowed/},
          {"fn [~s(x)] -> true end", 1, ~r/`sigil_s` is not allowed/},
          {"fn [a] when File.write!(a) -> true end", 1,
           ~r/not allowed in a match spec at line 1/},
          {"fn [a] when bsl(a, 2) > 0 -> true end", 1, ~r/bsl\/2 is not allowed/},
          {"fn [a] when is_integer(a, a) -> true end", 1, ~r/is_integer\/2 is not allowed/},
          {"fn [a] when a > 9223372036854775808 -> true end", 1, ~r/64 bits/},
          {~s(fn [:"$1"] -> true end), 1, ~r/reads as a match spec variable/},
          {"fn [:_] -> true end", 1, ~r/wildcard/},
          {eleven_clauses, 1, ~r/at most 10 clauses/},
          {many_vars, nil, ~r/at most 32 variables/},
          {products.(17), 1, ~r/at most 16/},
          {String.duplicate(" ", 4097), nil, ~r/longer than 4096 bytes/}
        ] do
      assert {:error, message} = MatchSpec.parse(source, arity)
      assert message =~ error, "#{source}: #{message}"
    end
  end

  test "creates no atoms" do
    source = fn i ->
      "fn [voy_var_#{i}, %{voy_key_#{i}: :voy_atom_#{i}}] when is_integer(voy_var_#{i}) -> true end"
    end

    {:ok, _spec} = MatchSpec.parse(source.(0), 2)
    before = :erlang.system_info(:atom_count)

    for i <- 1..100, do: {:ok, _spec} = MatchSpec.parse(source.(i), 2)

    assert :erlang.system_info(:atom_count) == before
  end

  defp placeholder_atoms({:"$voyager_atom", name}) when is_binary(name), do: :placeholder
  defp placeholder_atoms([head | tail]), do: [placeholder_atoms(head) | placeholder_atoms(tail)]

  defp placeholder_atoms(%{} = map),
    do: Map.new(map, fn {key, value} -> {placeholder_atoms(key), placeholder_atoms(value)} end)

  defp placeholder_atoms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> placeholder_atoms() |> List.to_tuple()

  defp placeholder_atoms(term), do: term
end
