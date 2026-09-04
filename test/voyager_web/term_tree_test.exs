defmodule VoyagerWeb.TermTreeTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"

  defp text(segments), do: Enum.map_join(segments, & &1.text)

  defp kinds(segments), do: Enum.map(segments, & &1.kind)

  defp child_keys(children) do
    Enum.map(children, fn
      {nil, _term} -> nil
      {segments, _term} -> text(segments)
    end)
  end

  defp child_terms(children), do: Enum.map(children, fn {_key, term} -> term end)

  describe "describe/2 leaves" do
    test "atoms carry their own segment kind" do
      assert %Node{kind: :atom, content: [%Segment{text: ":foo", kind: :atom}]} =
               TermTree.describe(:foo)

      assert %Node{content: [%Segment{text: "Foo.Bar", kind: :module}]} =
               TermTree.describe(Foo.Bar)

      for atom <- [nil, true, false] do
        assert %Node{kind: :atom, content: [%Segment{kind: :special} = segment]} =
                 TermTree.describe(atom)

        assert segment.text == inspect(atom)
      end
    end

    test "numbers" do
      assert %Node{kind: :number, content: [%Segment{text: "42", kind: :number}]} =
               TermTree.describe(42)

      assert %Node{kind: :number, content: [%Segment{text: "1.5", kind: :number}]} =
               TermTree.describe(1.5)
    end

    test "binaries are inspected as strings" do
      assert %Node{kind: :binary, content: [%Segment{text: ~s("hi"), kind: :string}]} =
               TermTree.describe("hi")

      assert %Node{kind: :binary, content: [%Segment{text: "<<255, 254>>"}]} =
               TermTree.describe(<<255, 254>>)
    end

    test "a long binary is cut down rather than rendered whole" do
      %Node{content: [segment]} = TermTree.describe(String.duplicate("a", 100_000))

      assert String.length(segment.text) < 5_000
      assert String.ends_with?(segment.text, "...")
    end

    test "a charlist reads as a charlist, not as a list of integers" do
      assert %Node{kind: :list, child_count: 0, content: [%Segment{text: ~s(~c"hi")}]} =
               TermTree.describe(~c"hi")
    end

    test "terms without literal syntax fall back to inspect" do
      assert %Node{kind: :other, content: [%Segment{kind: :other} = segment]} =
               TermTree.describe(self())

      assert segment.text == inspect(self())

      assert %Node{kind: :other, content: [%Segment{text: "~r/ab/"}]} =
               TermTree.describe(~r/ab/)

      assert %Node{kind: :other, content: [%Segment{text: "[1 | 2]"}]} =
               TermTree.describe([1 | 2])
    end

    test "the agent's truncation marker renders as a muted placeholder" do
      assert %Node{kind: :truncated, content: [%Segment{kind: :muted} = segment]} =
               TermTree.describe(@truncated)

      assert segment.text =~ "truncated"
    end

    test "empty collections are not expandable" do
      for {term, rendered, kind} <- [{{}, "{}", :tuple}, {[], "[]", :list}, {%{}, "%{}", :map}] do
        node = TermTree.describe(term)

        assert %Node{kind: ^kind, child_count: 0, content: [%Segment{text: ^rendered}]} = node
        refute Node.expandable?(node)
        assert node.expanded_before == []
        assert node.expanded_after == []
      end
    end
  end

  describe "describe/2 branches" do
    test "a tuple knows its size and both of its forms" do
      node = TermTree.describe({:ok, 1, 2})

      assert %Node{kind: :tuple, child_count: 3} = node
      assert Node.expandable?(node)
      assert text(node.content) == "{...}"
      assert text(node.expanded_before) == "{"
      assert text(node.expanded_after) == "}"
    end

    test "a list knows its length" do
      node = TermTree.describe([1, 2, 3])

      assert %Node{kind: :list, child_count: 3} = node
      assert text(node.content) == "[...]"
      assert text(node.expanded_before) == "["
      assert text(node.expanded_after) == "]"
    end

    test "a map knows its size" do
      node = TermTree.describe(%{a: 1, b: 2})

      assert %Node{kind: :map, child_count: 2} = node
      assert text(node.content) == "%{...}"
      assert text(node.expanded_before) == "%{"
      assert text(node.expanded_after) == "}"
    end

    test "a struct without an Inspect implementation renders as its module" do
      node = TermTree.describe(%State{})

      assert %Node{kind: :struct, child_count: 2} = node
      assert text(node.content) == "%VoyagerWeb.TermTree.State{...}"
      assert text(node.expanded_before) == "%VoyagerWeb.TermTree.State{"
      assert text(node.expanded_after) == "}"
      assert kinds(node.expanded_before) == [:punctuation, :module, :punctuation]
    end

    test "a struct with an Inspect implementation keeps that form when collapsed" do
      node = TermTree.describe(~D[2024-01-02])

      assert %Node{kind: :struct, content: [%Segment{text: "~D[2024-01-02]", kind: :other}]} =
               node

      assert text(node.expanded_before) == "%Date{"
    end

    test "a struct tagged with an Erlang module name keeps that name unquoted" do
      node = TermTree.describe(%{__struct__: :erl_record, a: 1})

      assert %Node{kind: :struct, child_count: 1} = node
      assert text(node.content) == "%erl_record{...}"
    end
  end

  describe "describe/2 options" do
    test "path is carried onto the node" do
      assert %Node{path: [1, 0]} = TermTree.describe(:foo, path: [1, 0])
      assert %Node{path: []} = TermTree.describe(:foo)
    end

    test "a key prefixes both the collapsed and the expanded opening" do
      key = [Segment.atom("name:"), Segment.punctuation(" ")]
      node = TermTree.describe(%{a: 1}, key: key)

      assert text(node.content) == "name: %{...}"
      assert text(node.expanded_before) == "name: %{"
      assert text(node.expanded_after) == "}"
    end

    test "a comma follows the value, collapsed or expanded" do
      node = TermTree.describe([1], comma?: true)

      assert text(node.content) == "[...],"
      assert text(node.expanded_before) == "["
      assert text(node.expanded_after) == "],"

      leaf = TermTree.describe(:foo, comma?: true)

      assert text(leaf.content) == ":foo,"
    end

    test "no comma is appended by default" do
      node = TermTree.describe([1])

      assert text(node.content) == "[...]"
      assert text(node.expanded_after) == "]"
    end
  end

  describe "children/3" do
    test "tuple and list children are positional" do
      assert TermTree.children({:ok, 1}, 0, 10) == [{nil, :ok}, {nil, 1}]
      assert TermTree.children([:a, :b], 0, 10) == [{nil, :a}, {nil, :b}]
    end

    test "keyword lists keep their own order and render their keys" do
      children = TermTree.children([b: 1, a: 2], 0, 10)

      assert child_keys(children) == ["b: ", "a: "]
      assert child_terms(children) == [1, 2]
    end

    test "map keys are sorted, since a map has no order of its own" do
      children = TermTree.children(%{c: 3, a: 1, b: 2}, 0, 10)

      assert child_keys(children) == ["a: ", "b: ", "c: "]
      assert child_terms(children) == [1, 2, 3]
    end

    test "non-atom keys are rendered with the arrow form" do
      children = TermTree.children(%{"z" => 1, 2 => :x, nil => :y}, 0, 10)

      assert child_keys(children) == ["2 => ", "nil => ", ~s("z" => )]
    end

    test "struct children are its fields, without __struct__" do
      children = TermTree.children(%State{}, 0, 10)

      assert child_keys(children) == ["open: ", "windows: "]
    end

    test "leaves and regexes have no children" do
      assert TermTree.children(~r/x/, 0, 10) == []
      assert TermTree.children(:foo, 0, 10) == []
      assert TermTree.children("hi", 0, 10) == []
      assert TermTree.children(123, 0, 10) == []
    end

    test "improper lists have no children, matching how they are described" do
      assert TermTree.children([1 | 2], 0, 10) == []
      assert TermTree.children(["hello" | "world"], 0, 10) == []
    end

    test "a struct key keeps its whole rendering, not just its first segment" do
      children = TermTree.children(%{%State{} => 1}, 0, 10)

      assert child_keys(children) == ["%VoyagerWeb.TermTree.State{...} => "]
    end

    test "offset and limit window the children" do
      assert TermTree.children([1, 2, 3, 4, 5], 1, 2) == [{nil, 2}, {nil, 3}]
      assert TermTree.children(Enum.to_list(1..100), 0, 50) |> length() == 50
      assert TermTree.children([1, 2, 3], 10, 5) == []

      children = TermTree.children(Map.new(1..5, &{&1, &1}), 2, 2)

      assert child_keys(children) == ["3 => ", "4 => "]
    end

    test "a truncation marker sits at the end of a map and carries no key" do
      children = TermTree.children(%{@truncated => :elided, a: 1}, 0, 10)

      assert child_keys(children) == ["a: ", nil]
      assert child_terms(children) == [1, @truncated]
    end

    test "keys are sorted up to the size where sorting stops paying off" do
      pairs = TermTree.children(Map.new(1..200, &{&1, &1}), 0, 200)

      assert child_terms(pairs) == Enum.to_list(1..200)
    end

    test "past that size every key is still reachable, at a stable position" do
      map = Map.new(1..201, &{&1, &1})
      pairs = TermTree.children(map, 0, 201)

      assert pairs |> child_terms() |> Enum.sort() == Enum.to_list(1..201)
      assert TermTree.children(map, 0, 201) == pairs
      assert TermTree.children(map, 150, 51) == Enum.slice(pairs, 150, 51)
    end
  end

  describe "initial_state/2" do
    test "the root is always open" do
      assert TermTree.open?(TermTree.initial_state(42), [])
      assert TermTree.open?(TermTree.initial_state(%{a: 1}), [])
    end

    test "short nested lists and tuples are opened along with the root" do
      state = TermTree.initial_state([1, [2, [3, [4]]]])

      assert state.open == MapSet.new([[], [1], [1, 1], [1, 1, 1]])
    end

    test "a short collection under a map key is opened too" do
      state = TermTree.initial_state(%{a: {1, 2}})

      assert state.open == MapSet.new([[], [0]])
    end

    test "collections long enough to need scrolling stay closed" do
      assert TermTree.initial_state([[1, 2, 3, 4, 5]]).open == MapSet.new([[]])
      assert TermTree.initial_state([Enum.to_list(1..100)]).open == MapSet.new([[]])
    end

    test "maps, charlists and empty collections are not opened automatically" do
      assert TermTree.initial_state([%{a: 1}]).open == MapSet.new([[]])
      assert TermTree.initial_state([~c"hi"]).open == MapSet.new([[]])
      assert TermTree.initial_state([[], {}]).open == MapSet.new([[]])
      assert TermTree.initial_state([[1 | 2]]).open == MapSet.new([[]])
    end

    test "an improper root is walked without raising" do
      assert TermTree.initial_state(["hello" | "world"]).open == MapSet.new([[]])
    end

    test "walking stops at :depth levels" do
      term = [1, [2, [3, [4, [5, [6]]]]]]

      assert TermTree.initial_state(term, depth: 1).open == MapSet.new([[], [1]])
      assert TermTree.initial_state(term, depth: 2).open == MapSet.new([[], [1], [1, 1]])
      assert TermTree.initial_state(term, depth: 0).open == MapSet.new([[]])
    end
  end

  describe "toggle/2" do
    test "opens a closed path and closes an open one" do
      state = TermTree.initial_state(42)

      refute TermTree.open?(state, [0])

      state = TermTree.toggle(state, [0])
      assert TermTree.open?(state, [0])

      state = TermTree.toggle(state, [0])
      refute TermTree.open?(state, [0])
    end

    test "the root can be closed like any other path" do
      state = 42 |> TermTree.initial_state() |> TermTree.toggle([])

      refute TermTree.open?(state, [])
    end

    test "toggling one path leaves the others alone" do
      state =
        %State{}
        |> TermTree.toggle([0])
        |> TermTree.toggle([1])
        |> TermTree.toggle([0])

      refute TermTree.open?(state, [0])
      assert TermTree.open?(state, [1])
    end
  end

  describe "expand_window/2" do
    test "an untouched path uses the default window" do
      assert TermTree.window(%State{}, []) == 50
    end

    test "each expansion pages in one more window" do
      state = TermTree.expand_window(%State{}, [0])

      assert TermTree.window(state, [0]) == 100
      assert TermTree.window(TermTree.expand_window(state, [0]), [0]) == 150
    end

    test "windows are tracked per path" do
      state = TermTree.expand_window(%State{}, [0])

      assert TermTree.window(state, [1]) == 50
    end
  end

  describe "path encoding" do
    test "round-trips" do
      for path <- [[], [0], [1, 0, 12]] do
        assert path |> TermTree.encode_path() |> TermTree.decode_path() == {:ok, path}
      end
    end

    test "the root encodes to an empty string" do
      assert TermTree.encode_path([]) == ""
      assert TermTree.decode_path("") == {:ok, []}
    end

    test "a path that is not a list of integers is rejected" do
      assert TermTree.decode_path("a") == :error
      assert TermTree.decode_path("1..2") == :error
      assert TermTree.decode_path("1.x") == :error
      assert TermTree.decode_path(".") == :error
    end

    test "a path that is not a string is rejected" do
      assert TermTree.decode_path(nil) == :error
      assert TermTree.decode_path(["0"]) == :error
      assert TermTree.decode_path(%{"0" => "1"}) == :error
    end
  end

  describe "copy_string/1" do
    test "renders the whole term, not the shortened display form" do
      copied = TermTree.copy_string(Enum.to_list(1..300))

      assert copied =~ "300"
      refute copied =~ "..."
    end

    test "keeps long binaries intact" do
      binary = String.duplicate("a", 10_000)

      assert TermTree.copy_string(binary) == inspect(binary, printable_limit: :infinity)
    end

    test "rewrites pids into something that can be pasted into IEx" do
      pid = :erlang.list_to_pid(~c"<0.123.0>")
      copied = TermTree.copy_string(%{pid: pid})

      refute copied =~ "#PID"
      assert copied =~ ~s|:erlang.list_to_pid(~c"<0.123.0>")|

      assert {%{pid: ^pid}, _binding} = Code.eval_string(copied)
    end

    test "quotes other #Name<...> forms so the result still parses" do
      copied = TermTree.copy_string([make_ref()])

      assert copied =~ ~r/\["#Reference<[\d.]+>"\]/
      assert {[reference], _binding} = Code.eval_string(copied)
      assert is_binary(reference)
    end

    test "leaves a #Name<...> form inside a binary alone" do
      log = "boot #PID<0.1.0> ready #Foo<1>"
      copied = TermTree.copy_string(%{log: log})

      assert {%{log: ^log}, _binding} = Code.eval_string(copied)
    end

    test "expands structs, which have no literal form on the far side" do
      copied = TermTree.copy_string(~D[2024-01-02])

      assert copied =~ "__struct__: Date"
      assert {%{__struct__: Date}, _binding} = Code.eval_string(copied)
    end
  end
end
