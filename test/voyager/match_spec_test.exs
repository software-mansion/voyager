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
    test "parses the match-all spec" do
      assert MatchSpec.parse("[{'$1', [], ['$1']}].") == {:ok, [{:"$1", [], [:"$1"]}]}
    end

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

    test "parses several clauses" do
      assert {:ok, [{[:"$1"], [{:>, :"$1", 10}], [{:return_trace}]}, {:_, [], []}]} =
               MatchSpec.parse(~S([{['$1'], [{'>', '$1', 10}], [{return_trace}]}, {'_', [], []}]))
    end

    test "returns a term of any shape" do
      assert MatchSpec.parse("42") == {:ok, 42}
      assert MatchSpec.parse("[]") == {:ok, []}
      assert MatchSpec.parse("{a, b}") == {:ok, {:a, :b}}
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
      for input <- ["", "  ", ".", "[{'$1', [], ['$1']}", "'unterminated", "a. b.", "{a,,}"] do
        assert {:error, {:syntax, _message}} = MatchSpec.parse(input), inspect(input)
      end
    end

    test "rejects invalid UTF-8 without raising" do
      assert MatchSpec.parse(<<"[", 255, "]">>) == {:error, {:syntax, "not valid UTF-8"}}
    end

    test "refuses sized binary segments before building them" do
      for input <- ["<<0:800000000>>", "<<0:99999999999999>>", "<<1:8/unit:8>>", "<<\"a\":8>>"] do
        assert MatchSpec.parse(input) ==
                 {:error, {:syntax, "calls and sized binary segments are not allowed"}},
               input
      end
    end

    test "keeps colons inside quoted atoms and strings" do
      assert MatchSpec.parse(~S(['a:b', "c:d", <<"e:f">>])) == {:ok, [:"a:b", ~c"c:d", "e:f"]}
    end

    test "accepts 4096 bytes and refuses one more" do
      term = "[{'$1', [], ['$1']}]"
      at_cap = term <> String.duplicate(" ", 4_096 - byte_size(term))

      assert byte_size(at_cap) == 4_096
      assert {:ok, _spec} = MatchSpec.parse(at_cap)
      assert MatchSpec.parse(at_cap <> " ") == {:error, :too_large}
    end
  end

  describe "check_shape/1" do
    test "accepts one or more clauses" do
      assert MatchSpec.check_shape([{:_, [], []}]) == :ok
      assert MatchSpec.check_shape([{[:"$1"], [{:>, :"$1", 1}], [true]}, {:_, [], []}]) == :ok
    end

    test "rejects every other term" do
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

    test "rejects a term that is not a spec" do
      for term <- @not_specs do
        assert MatchSpec.check_clauses(term, 10) == {:error, :invalid_shape}, inspect(term)
      end
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

    test "rejects a term that is not a spec" do
      for term <- @not_specs do
        assert MatchSpec.check_actions(term, @refused) == {:error, :invalid_shape}, inspect(term)
      end
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
            {[{"head", [], []}], :trace}
          ] do
        assert {:error, {:compile, [_ | _] = errors}} = MatchSpec.check_compiles(spec, type),
               inspect(spec)

        assert Enum.all?(errors, &is_binary/1)
      end
    end

    test "rejects a term that is not a spec" do
      for term <- @not_specs, type <- [:table, :trace] do
        assert MatchSpec.check_compiles(term, type) == {:error, :invalid_shape}, inspect(term)
      end
    end
  end

  test "checks compose over a parsed spec" do
    input = ~S([{['$1', '_'], [{'>', '$1', 10}], [{message, '$1'}]}, {'_', [], []}])

    assert {:ok, spec} = MatchSpec.parse(input)
    assert MatchSpec.check_clauses(spec, 10) == :ok
    assert MatchSpec.check_actions(spec, [:return_trace]) == :ok
    assert MatchSpec.check_compiles(spec, :trace) == :ok
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
      for variable <- [:_, :"$_", :"$$", :"$0", :"$1", :"$123", :"$007"] do
        assert MatchSpec.encode([{variable, [], [variable]}]) == [{variable, [], [variable]}]
      end
    end

    test "tags atoms that only look like variables" do
      for atom <- [:"$", :"$abc", :"$1a", :"$-1", :__, :"$__"] do
        assert MatchSpec.encode([{atom, [], []}]) == [{tag(atom), [], []}], inspect(atom)
      end
    end

    test "tags atoms inside maps, nested tuples and improper lists" do
      spec = [{{%{key: [:a | :b]}}, [], [{:const, {{:c}}}]}]

      assert MatchSpec.encode(spec) == [
               {{%{tag(:key) => [tag(:a) | tag(:b)]}}, [], [{tag(:const), {{tag(:c)}}}]}
             ]
    end

    test "leaves numbers and binaries alone" do
      spec = [{[1, -2.5, "atom"], [], [~c"ab"]}]

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
            {{:syntax, "syntax error before: ')'"}, "syntax error before: ')'"},
            {:invalid_shape, "expected a list of {head, guards, body} clauses"},
            {{:too_many_clauses, 1}, "expected one {head, guards, body} clause"},
            {{:too_many_clauses, 10}, "expected at most 10 clauses"},
            {{:refused_action, :return_trace}, "the return_trace action is not allowed"},
            {{:compile, ["Variable $7 is unbound.", "Bad."]}, "Variable $7 is unbound. Bad."},
            {{:unknown_atom, "nope"}, "atom 'nope' does not exist on the node"}
          ] do
        assert MatchSpec.format_error(reason) == message
      end
    end

    test "formats what parse/1 and the checks return" do
      assert {:error, reason} = MatchSpec.parse("[{X, [], []}]")
      assert MatchSpec.format_error(reason) =~ "bad term"

      assert {:error, reason} = MatchSpec.check_compiles([{:_, [], [:"$7"]}], :trace)
      assert MatchSpec.format_error(reason) == "Variable $7 is unbound."
    end
  end

  defp tag(atom), do: {@tag_atom, Atom.to_string(atom)}
end
