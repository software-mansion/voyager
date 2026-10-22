defmodule VoyagerWeb.TermFormatterTest do
  use ExUnit.Case, async: true

  import Voyager.TestUtils, only: [erl_eval: 1]

  alias VoyagerWeb.TermFormatter
  alias VoyagerWeb.TermFormatter.Erlang, as: ErlangFormatter

  defp erlang(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :erlang] ++ opts)
  defp elixir(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :elixir] ++ opts)

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

  defp random_data(0) do
    Enum.random([
      :ok,
      :"it's",
      :żółć,
      -1,
      ?a,
      159,
      0x10FFFF,
      10 ** 30,
      -0.0,
      5.0e-324,
      "",
      "zażółć",
      <<"ab", 255>>,
      <<"ab", 1::3>>,
      [],
      {},
      %{}
    ])
  end

  defp random_data(depth) do
    items = Enum.map(1..:rand.uniform(4), fn _ -> random_data(depth - 1) end)

    case :rand.uniform(6) do
      1 -> List.to_tuple(items)
      2 -> items
      3 -> Map.new(items, &{&1, random_data(depth - 1)})
      4 -> [?a, random_data(0) | random_data(0)]
      5 -> Enum.map(items, fn _ -> Enum.random([?a, ?λ, 10, 160]) end)
      _ -> random_data(0)
    end
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
        [?h, ?i | "!"],
        [?h, ?i | ""],
        {:state, [], %{k: {1, 2}}},
        %{"b" => [1, 2], a: 1},
        %URI{host: "x"},
        ~D[2026-10-15],
        1..10//2
      ]

      for term <- terms do
        assert erl_eval(erlang(term, limit: :infinity, printable_limit: :infinity)) == term
      end
    end

    test "prints Elixir structs as the maps they are" do
      assert erlang(%URI{host: "x"}) =~ ~S|#{'__struct__' => 'Elixir.URI',|
      assert erlang(a: 1) == "[{a, 1}]"
    end

    test "prints any data term as Erlang that parses back to the same term" do
      for _ <- 1..1_000, term = random_data(4) do
        assert erl_eval(erlang(term, limit: :infinity, printable_limit: :infinity)) === term
        assert erl_eval(ErlangFormatter.copy_string(term, width: 20)) === term
      end
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

      assert erl_eval(ErlangFormatter.copy_string(term)) == term
    end

    test "round-trip output keeps a local fun as its text" do
      fun = fn -> :ok end

      assert erl_eval(ErlangFormatter.copy_string(fun)) ==
               fun |> :erlang.fun_to_list() |> to_string() |> to_charlist()
    end

    test "renders any term without raising" do
      for _ <- 1..500,
          term = random_term(4),
          opts <- [[], [limit: 0, printable_limit: 0], [pretty: true, width: 5]] do
        assert is_binary(erlang(term, opts))
        assert is_binary(ErlangFormatter.copy_string(term, opts))
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
