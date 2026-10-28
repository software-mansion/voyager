defmodule VoyagerWeb.TermFormatterTest do
  use ExUnit.Case, async: true

  import Voyager.TestUtils, only: [erl_eval: 1]

  alias VoyagerWeb.TermFormatter

  @atoms [:ok, :"hello world", :"it's", :żółć, :end, Enum, nil]
  @numbers [-3, ?a, 159, 0x10FFFF, 10 ** 40, 0.1, -0.0, 5.0e-324]
  @binaries ["", "abc", "zażółć", <<"ab", 255>>, <<1, 2, 5::3>>]
  @lists [
    [],
    ~c"hi",
    ~c"zażółć",
    [?a, ?λ, 10, 160],
    [a: 1, b: 2],
    [1, 2 | :tail],
    [?h, ?i | "!"],
    [?h, ?i | ""]
  ]
  @tuples [{}, {:state, [], %{k: {1, 2}}}]
  @maps [%{}, %{"b" => [1, 2], a: 1}]
  @structs [
    %URI{host: "x"},
    ~D[2026-10-15],
    ~U[2026-10-15 12:00:00Z],
    1..10//2,
    MapSet.new([1, :a])
  ]
  @complex %{@binaries => @lists, tuples: @tuples, maps: @maps, items: Enum.to_list(1..30)}
  @data @atoms ++
          @numbers ++
          @binaries ++ @lists ++ @tuples ++ @maps ++ @structs ++ [&Enum.map/2, @complex]

  @raising_struct %{__struct__: Date, calendar: Calendar.ISO, year: "x", month: 1, day: 1}
  @unknown_struct %{__struct__: "not a module", a: 1}

  defp erlang(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :erlang] ++ opts)
  defp elixir(term, opts \\ []), do: TermFormatter.inspect(term, [syntax: :elixir] ++ opts)

  defp erlang_copy(term, opts \\ []),
    do: TermFormatter.copy_string(term, [syntax: :erlang] ++ opts)

  defp elixir_copy(term, opts \\ []),
    do: TermFormatter.copy_string(term, [syntax: :elixir] ++ opts)

  defp any_terms do
    unusual = [self(), make_ref(), hd(Port.list()), fn -> :ok end, ~r/a(b)?/u]
    terms = @data ++ unusual ++ [@raising_struct, @unknown_struct]

    [terms | terms]
  end

  describe "inspect/2 with the Erlang syntax" do
    test "prints data as Erlang that evaluates back to the same term" do
      for term <- @data do
        assert erl_eval(erlang(term, limit: :infinity, printable_limit: :infinity)) === term
      end
    end

    test "prints Elixir structs and keyword lists as plain Erlang data" do
      keyword = [a: 1]

      assert erlang(%URI{host: "x"}) =~ ~S|#{'__struct__' => 'Elixir.URI',|
      assert erlang(keyword) == "[{a, 1}]"
    end

    test "cuts each collection at the limit" do
      assert erlang(Enum.to_list(1..10), limit: 3) == "[1, 2, 3 | ...]"
      assert erlang([1, 2], limit: 0) == "[...]"
      assert erlang([1, 2 | :tail], limit: 2) == "[1, 2 | tail]"
      assert erlang({1, 2, 3, 4}, limit: 2) == "{1, 2, ...}"
      assert erlang(%{a: 1, b: 2}, limit: 1) == "\#{a => 1, ... => ...}"
      assert erlang(<<200, 1, 2>>, limit: 2) == "<<200,1,...>>"
    end

    test "spends one limit across nested collections" do
      assert erlang([[1, 2, 3], [4, 5, 6], [7, 8, 9]], limit: 5) == "[[1, 2, 3], [...] | ...]"
      assert erlang({{1, 2}, {3, 4}}, limit: 3) == "{{1, 2}, ...}"
      assert erlang(%{a: [1, 2], b: [3, 4]}, limit: 3) == "\#{a => [1, 2], ... => ...}"
      assert erlang([<<1, 2, 3>>, <<4>>], limit: 3) == "[<<1,2,...>> | ...]"
      assert erlang(["abcdef", [1, 2]], limit: 2) == ~S|[<<"abcdef">>, [...]]|
      assert erlang([1, 2 | {3, 4}], limit: 3) == "[1, 2 | {...}]"
    end

    test "cuts text at the printable limit" do
      assert erlang(String.duplicate("a", 10), printable_limit: 3) == ~S|<<"aaa",...>>|
      assert erlang(~c"abcdef", printable_limit: 3) == ~S|"abc" ++ ...|
      assert erlang("abc" <> <<255>>, printable_limit: 2) == ~S|<<"ab",...>>|
    end

    test "prints a list as a string only within ASCII" do
      assert erlang(~c"hi\n") == ~S|"hi\n"|
      assert erlang([200, 201, 204]) == "[200, 201, 204]"
      assert erlang(~c"café") == "[99, 97, 102, 233]"
    end

    test "prints a UTF-8 binary as text" do
      assert erlang("zażółć") == ~S|<<"zażółć"/utf8>>|
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

    test "renders any term without raising" do
      for term <- any_terms(),
          opts <- [[], [limit: 0, printable_limit: 0], [pretty: true, width: 5]] do
        assert is_binary(erlang(term, opts))
      end
    end
  end

  describe "copy_string/2 with the Erlang syntax" do
    test "evaluates back to the same term when wrapped" do
      for term <- @data do
        assert erl_eval(erlang_copy(term, width: 20)) === term
      end
    end

    test "evaluates back to the same term, opaque values included" do
      term = {self(), make_ref(), hd(Port.list()), &Enum.map/2, %URI{host: "zażółć"}, [1 | 2]}

      assert erl_eval(erlang_copy(term)) == term
    end

    test "keeps a local fun as its text" do
      fun = fn -> :ok end

      assert erl_eval(erlang_copy(fun)) ==
               fun |> :erlang.fun_to_list() |> to_string() |> to_charlist()
    end

    test "renders the whole term" do
      copied = erlang_copy(Enum.to_list(1..300))

      assert copied =~ "300"
      refute copied =~ "..."
    end

    test "renders any term without raising" do
      for term <- any_terms(), opts <- [[], [width: 5]] do
        assert is_binary(erlang_copy(term, opts))
      end
    end
  end

  describe "copy_string/2 with the Elixir syntax" do
    test "evaluates back to the same term when wrapped" do
      for term <- @data do
        assert {^term, _binding} = Code.eval_string(elixir_copy(term, width: 20))
      end
    end

    test "copies a cut binary with its prefix and size" do
      record = {{:"$voyager_truncated", :binary, "abc", 100_000}, :"$voyager_truncated"}

      assert {^record, _binding} = Code.eval_string(elixir_copy(record))
    end

    test "renders the whole term, not the shortened display form" do
      copied = elixir_copy(Enum.to_list(1..300))

      assert copied =~ "300"
      refute copied =~ "..."
    end

    test "keeps long binaries intact" do
      binary = String.duplicate("a", 10_000)

      assert elixir_copy(binary) == inspect(binary, printable_limit: :infinity)
    end

    test "rewrites pids into something that can be pasted into IEx" do
      pid = :erlang.list_to_pid(~c"<0.123.0>")
      copied = elixir_copy(%{pid: pid})

      refute copied =~ "#PID"
      assert copied =~ ~s|:erlang.list_to_pid(~c"<0.123.0>")|

      assert {%{pid: ^pid}, _binding} = Code.eval_string(copied)
    end

    test "rebuilds references and ports with their list_to_* BIF" do
      term = [make_ref(), hd(Port.list())]

      assert {^term, _binding} = Code.eval_string(elixir_copy(term))
    end

    test "quotes a local fun, which has no literal form" do
      fun = fn -> :ok end

      assert {"#Function<" <> _, _binding} = Code.eval_string(elixir_copy(fun))
    end

    test "leaves a #Name<...> form inside a binary alone" do
      log = "boot #PID<0.1.0> ready #Foo<1>"
      copied = elixir_copy(%{log: log})

      assert {%{log: ^log}, _binding} = Code.eval_string(copied)
    end

    test "expands structs, which have no literal form on the far side" do
      copied = elixir_copy(~D[2024-01-02])

      assert copied =~ "__struct__: Date"
      assert {%{__struct__: Date}, _binding} = Code.eval_string(copied)
    end

    test "renders any term without raising" do
      for term <- any_terms(), opts <- [[], [width: 5]] do
        assert is_binary(elixir_copy(term, opts))
      end
    end
  end

  describe "inspect/2 with the Elixir syntax" do
    test "renders as Kernel.inspect/2 does" do
      for term <- @data do
        assert elixir(term) == inspect(term)
      end
    end

    test "falls back to the plain struct when its Inspect implementation raises" do
      date = %{__struct__: Date, calendar: Calendar.ISO, year: "x", month: 1, day: 1}

      assert elixir({:ok, date}) ==
               ~S|{:ok, %Date{year: "x", month: 1, day: 1, calendar: Calendar.ISO}}|
    end

    test "renders any term without raising" do
      for term <- any_terms() do
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
