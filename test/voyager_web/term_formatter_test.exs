defmodule VoyagerWeb.TermFormatterTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.TermFormatter

  defp erlang(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :erlang] ++ opts)
  defp elixir(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :elixir] ++ opts)

  defp evaluate(text) do
    {:ok, tokens, _end} = :erl_scan.string(String.to_charlist(text <> "."))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    {:value, value, _bindings} = :erl_eval.exprs(exprs, :erl_eval.new_bindings())
    value
  end

  defp random_term(0), do: random_leaf()

  defp random_term(depth) do
    case :rand.uniform(6) do
      1 ->
        List.to_tuple(for _ <- 1..:rand.uniform(4), do: random_term(depth - 1))

      2 ->
        for _ <- 1..:rand.uniform(4), do: random_term(depth - 1)

      3 ->
        Map.new(1..:rand.uniform(3), fn _ -> {random_term(depth - 1), random_term(depth - 1)} end)

      4 ->
        [random_term(depth - 1) | random_leaf()]

      _ ->
        random_leaf()
    end
  end

  defp random_leaf do
    Enum.random([
      :ok,
      Enum,
      :"needs quotes",
      -7,
      10 ** 30,
      2.5,
      "text",
      "zażółć",
      <<200, 1>>,
      <<1::5>>,
      ~c"chars",
      [],
      {},
      %{},
      %URI{host: "x"},
      ~U[2026-10-15 12:00:00Z],
      MapSet.new([1, :a]),
      ~r/a(b)?/u,
      %{__struct__: Date, calendar: Calendar.ISO, year: "x", month: 1, day: 1},
      %{__struct__: "not a module", a: 1},
      self(),
      make_ref(),
      &Enum.map/2,
      fn -> :ok end
    ])
  end

  describe "inspect/2 with the Erlang syntax" do
    test "prints literal terms as Erlang that parses back to the same term" do
      terms = [
        :ok,
        :"hello world",
        :end,
        Enum,
        nil,
        -3,
        10 ** 40,
        0.1,
        "abc",
        "zażółć",
        <<1, 2, 3>>,
        <<1, 2, 5::3>>,
        "",
        ~c"hi",
        ~c"zażółć",
        [a: 1, b: 2],
        [1, 2 | :x],
        {:state, [], %{k: {1, 2}}},
        %{"b" => [1, 2], a: 1},
        %URI{host: "x"},
        ~D[2026-10-15],
        1..10//2
      ]

      for term <- terms do
        assert evaluate(erlang(term, limit: :infinity, printable_limit: :infinity)) == term
      end
    end

    test "prints Elixir structs as the maps they are" do
      assert erlang(%URI{host: "x"}) =~ ~S|#{'__struct__' => 'Elixir.URI',|
      assert erlang(a: 1) == "[{a, 1}]"
    end

    test "cuts each collection at the limit" do
      assert erlang(Enum.to_list(1..10), limit: 3) == "[1, 2, 3 | ...]"
      assert erlang([1, 2], limit: 0) == "[...]"
      assert erlang([1, 2 | :tail], limit: 2) == "[1, 2 | tail]"
      assert erlang({1, 2, 3, 4}, limit: 2) == "{1, 2, ...}"
      assert erlang(%{a: 1, b: 2}, limit: 1) == "\#{a => 1, ... => ...}"
      assert erlang(<<200, 1, 2>>, limit: 2) == "<<200,1,...>>"
    end

    test "cuts text at the printable limit" do
      assert erlang(String.duplicate("a", 10), printable_limit: 3) == ~S|<<"aaa",...>>|
      assert erlang(~c"abcdef", printable_limit: 3) == ~S|"abc" ++ ...|
      assert erlang("abc" <> <<255>>, printable_limit: 2) == ~S|<<"ab",...>>|
    end

    test "prints Unicode text whatever the VM's printable range" do
      assert erlang("zażółć") == ~S|<<"zażółć"/utf8>>|
      assert erlang(~c"zażółć") == ~S|"zażółć"|
      assert erlang(<<"ab", 255>>) == "<<97,98,255>>"
    end

    test "prints refs and local funs as the shell shows them" do
      ref = make_ref()
      fun = fn -> :ok end

      assert erlang({ref, fun}) ==
               "{#{:erlang.ref_to_list(ref)}, #{:erlang.fun_to_list(fun)}}"
    end

    test "breaks lines only when pretty" do
      term = %{opts: [timeout: 5_000], state: Enum.to_list(1..30)}

      assert erlang(term, pretty: true, width: 30, limit: 5) =~ "\n"
      refute erlang(term, width: 30, limit: 5) =~ "\n"
    end

    test "round-trip output evaluates back to the same term, opaque values included" do
      term = {self(), make_ref(), hd(Port.list()), &Enum.map/2, %URI{host: "zażółć"}, [1 | 2]}

      assert evaluate(erlang(term, round_trip: true)) == term
    end

    test "round-trip output keeps a local fun as its text" do
      fun = fn -> :ok end

      assert evaluate(erlang(fun, round_trip: true)) ==
               fun |> :erlang.fun_to_list() |> to_string() |> to_charlist()
    end

    test "renders any term without raising" do
      for _ <- 1..500,
          term = random_term(4),
          opts <- [[], [limit: 0, printable_limit: 0], [pretty: true, width: 5]] do
        assert is_binary(erlang(term, opts))
        assert is_binary(erlang(term, [round_trip: true] ++ opts))
      end
    end
  end

  describe "inspect/2 with the Elixir syntax" do
    test "renders as Kernel.inspect/2 does" do
      term = %{list: [a: 1], uri: %URI{host: "x"}, tuple: {:ok, ~c"hi"}}

      assert elixir(term) == inspect(term)
    end

    test "falls back to the plain struct when its Inspect implementation raises" do
      date = %{__struct__: Date, calendar: Calendar.ISO, year: "x", month: 1, day: 1}

      assert elixir({:ok, date}) ==
               ~S|{:ok, %Date{year: "x", month: 1, day: 1, calendar: Calendar.ISO}}|
    end

    test "renders any term without raising" do
      for _ <- 1..500, term = random_term(4) do
        assert is_binary(elixir(term, limit: 10, printable_limit: 5))
      end
    end
  end

  describe "format_mfa/2" do
    test "renders the call target in either syntax" do
      assert TermFormatter.format_mfa({Enum, :map, 2}, syntax: :elixir) == "Enum.map/2"

      assert TermFormatter.format_mfa({:gen_server, :loop, 7}, syntax: :elixir) ==
               ":gen_server.loop/7"

      assert TermFormatter.format_mfa({Enum, :map, 2}, syntax: :erlang) == "'Elixir.Enum':map/2"

      assert TermFormatter.format_mfa({:gen_server, :loop, 7}, syntax: :erlang) ==
               "gen_server:loop/7"
    end

    test "inspects anything that is not an mfa" do
      assert TermFormatter.format_mfa(:undefined, syntax: :erlang) == "undefined"
      assert TermFormatter.format_mfa(nil, syntax: :elixir) == "nil"
    end
  end
end
