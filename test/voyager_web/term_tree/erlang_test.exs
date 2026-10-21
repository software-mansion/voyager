defmodule VoyagerWeb.TermTree.ErlangTest do
  use ExUnit.Case, async: true

  import Voyager.TestUtils, only: [erl_eval: 1]

  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"

  defp describe_erl(term, opts \\ []), do: TermTree.describe(term, [syntax: :erlang] ++ opts)
  defp children_erl(term), do: TermTree.children(term, 0, 50, syntax: :erlang)
  defp copy_erl(term), do: TermTree.copy_string(term, syntax: :erlang)

  defp text(segments), do: Enum.map_join(segments, & &1.text)

  defp child_keys(children) do
    Enum.map(children, fn
      {nil, _term} -> nil
      {segments, _term} -> text(segments)
    end)
  end

  defp child_terms(children), do: Enum.map(children, fn {_key, term} -> term end)

  describe "describe/2 leaves" do
    test "atoms are written as Erlang spells them" do
      assert %Node{content: [%Segment{text: "ok", kind: :atom}]} = describe_erl(:ok)
      assert %Node{content: [%Segment{text: "'Elixir.Foo.Bar'"}]} = describe_erl(Foo.Bar)
      assert %Node{content: [%Segment{text: "'hello world'"}]} = describe_erl(:"hello world")
      assert %Node{content: [%Segment{text: "nil", kind: :atom}]} = describe_erl(nil)

      for atom <- [true, false, :undefined] do
        assert %Node{content: [%Segment{kind: :special}]} = describe_erl(atom)
      end
    end

    test "binaries and strings" do
      assert %Node{kind: :binary, content: [%Segment{text: ~S|<<"hi">>|, kind: :string}]} =
               describe_erl("hi")

      assert %Node{content: [%Segment{text: "<<0,1>>"}]} = describe_erl(<<0, 1>>)

      assert %Node{kind: :list, child_count: 0, content: [%Segment{text: ~S|"hi"|}]} =
               describe_erl(~c"hi")
    end

    test "terms without literal syntax use their Erlang form" do
      assert %Node{kind: :other, content: [%Segment{text: "[1 | 2]"}]} = describe_erl([1 | 2])

      assert %Node{content: [%Segment{text: "fun 'Elixir.Enum':map/2"}]} =
               describe_erl(&Enum.map/2)

      assert %Node{content: [%Segment{text: "#Ref<" <> _}]} = describe_erl(make_ref())
    end

    test "a cut binary renders its prefix as a binary and a muted elision" do
      node = describe_erl({@truncated, :binary, "abc", 100_000})

      assert text(node.content) == ~S|<<"abc">> … (truncated, 100000 bytes)|
      refute Node.expandable?(node)
    end

    test "an empty map reads as an Erlang map" do
      assert %Node{content: [%Segment{text: "\#{}"}]} = describe_erl(%{})
    end
  end

  describe "describe/2 branches" do
    test "maps read as Erlang maps" do
      node = describe_erl(%{a: 1})

      assert %Node{kind: :map, child_count: 1} = node
      assert text(node.content) == "\#{...}"
      assert text(node.expanded_before) == "\#{"
    end

    test "a struct is the map it is, its __struct__ key counted" do
      node = describe_erl(%State{})

      assert %Node{kind: :map, child_count: 3} = node
      assert text(node.content) == "\#{...}"
    end

    test "a map cut short on the remote node is flagged" do
      assert %Node{truncated?: true} = describe_erl(%{@truncated => @truncated, a: 1})
    end
  end

  describe "children/4" do
    test "keyword lists are plain lists of tuples" do
      children = children_erl(b: 1, a: 2)

      assert child_keys(children) == [nil, nil]
      assert child_terms(children) == [{:b, 1}, {:a, 2}]
    end

    test "map keys are sorted and joined with =>" do
      children = children_erl(%{"z" => 1, b: 2, a: 3})

      assert child_keys(children) == ["a => ", "b => ", ~S|<<"z">> => |]
    end

    test "struct fields include __struct__" do
      assert child_keys(children_erl(%State{})) == ["'__struct__' => ", "open => ", "windows => "]
    end

    test "container keys are rendered whole" do
      assert child_keys(children_erl(%{{:a, 1} => :x})) == ["{a, 1} => "]
    end

    test "a truncation marker sits at the end of a map and carries no key" do
      children = children_erl(%{@truncated => :elided, a: 1})

      assert child_keys(children) == ["a => ", nil]
    end

    test "strings and improper lists have no children" do
      assert children_erl(~c"hi") == []
      assert children_erl([1 | 2]) == []
    end
  end

  describe "initial_state/2" do
    test "opens short lists and tuples, not strings" do
      state = TermTree.initial_state([{:a, 1}, ~c"hi"], syntax: :erlang)

      assert state.open == MapSet.new([[], [0]])
    end
  end

  describe "copy_string/2" do
    test "round-trips through the Erlang shell" do
      term = %{
        list: [1, 2 | :tail],
        binary: "zażółć",
        bits: <<1, 2::3>>,
        float: 1.5,
        tuple: {:ok, ~c"chars", nil},
        fun: &Enum.map/2,
        struct: %State{}
      }

      assert erl_eval(copy_erl(term)) == term
    end

    test "rewrites pids, refs and ports into calls that rebuild them" do
      ref = make_ref()
      port = hd(Port.list())
      term = {self(), ref, port}
      copied = copy_erl(term)

      assert copied =~ "list_to_pid("
      assert erl_eval(copied) == term
    end

    test "quotes local funs, which have no literal form" do
      assert ~c"#Fun<" ++ _ = erl_eval(copy_erl(fn -> :ok end))
    end

    test "renders the whole term" do
      copied = copy_erl(Enum.to_list(1..300))

      assert copied =~ "300"
      refute copied =~ "..."
    end
  end
end
