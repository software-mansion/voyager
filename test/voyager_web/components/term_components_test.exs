defmodule VoyagerWeb.Components.TermComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.State

  defp render_term(term, opts \\ []) do
    assigns =
      opts
      |> Keyword.put_new(:id, "term")
      |> Keyword.put_new(:state, TermTree.initial_state(term))
      |> Keyword.put(:term, term)

    render_component(&TermComponents.term_inspector/1, assigns)
    |> LazyHTML.from_fragment()
  end

  defp select(doc, selector), do: LazyHTML.query(doc, selector)

  defp count(doc, selector), do: doc |> select(selector) |> Enum.count()

  defp attribute(doc, selector, name) do
    doc |> select(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp texts(doc, selector) do
    doc |> select(selector) |> Enum.map(&LazyHTML.text/1)
  end

  defp text(doc, selector) do
    doc
    |> select(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp open(paths), do: %State{open: MapSet.new(paths)}

  describe "term_inspector/1" do
    test "a leaf renders its value and nothing to click" do
      doc = render_term(42)

      assert count(doc, "#term") == 1
      assert count(doc, "button") == 0
      assert text(doc, "#term") == "42"
    end

    test "a collapsed branch renders only its own line" do
      doc = render_term(%{a: %{b: 1}}, state: open([]))

      assert count(doc, "li") == 0
      assert text(doc, "#term-root-toggle") == "%{...}"
    end

    test "an open branch renders one list item per child" do
      doc = render_term([:a, :b, :c], state: open([[]]))

      assert count(doc, "li") == 3
      assert count(doc, "li#term-0") == 1
      assert count(doc, "li#term-2") == 1
      assert text(doc, "#term-0") == ":a,"
      assert text(doc, "#term-2") == ":c"
    end

    test "children are addressed by their path, at any depth" do
      doc = render_term([[1, 2]], state: open([[], [0]]))

      assert count(doc, "li#term-0") == 1
      assert count(doc, "li#term-0-0") == 1
      assert count(doc, "li#term-0-1") == 1
      assert count(doc, "#term-0-toggle") == 1
    end

    test "only open paths are rendered, so a closed sibling costs nothing" do
      doc = render_term([[1, 2], [3, 4]], state: open([[], [1]]))

      assert count(doc, "li#term-1-0") == 1
      assert count(doc, "li#term-0-0") == 0
    end

    test "map keys are rendered next to their values" do
      doc = render_term(%{name: "voyager", port: 4000}, state: open([[]]))

      assert text(doc, "#term-0") == "name: \"voyager\","
      assert text(doc, "#term-1") == "port: 4000"
    end

    test "the toggle carries the inspector id and the encoded path" do
      doc = render_term(%{a: %{b: 1}}, state: open([[], [0]]))

      assert attribute(doc, "#term-root-toggle", "phx-click") == "term-toggle"
      assert attribute(doc, "#term-root-toggle", "phx-value-id") == "term"
      assert attribute(doc, "#term-root-toggle", "phx-value-path") == ""
      assert attribute(doc, "#term-0-toggle", "phx-value-path") == "0"
    end

    test "the toggle announces whether its branch is open" do
      open = render_term(%{a: 1}, state: open([[]]))
      collapsed = render_term(%{a: 1}, state: open([]))

      assert attribute(open, "#term-root-toggle", "aria-expanded") == "true"
      assert attribute(collapsed, "#term-root-toggle", "aria-expanded") == "false"
    end

    test "event names can be overridden per inspector" do
      doc =
        render_term(Enum.to_list(1..60),
          state: open([[]]),
          toggle_event: "custom-toggle",
          window_event: "custom-window"
        )

      assert attribute(doc, "#term-root-toggle", "phx-click") == "custom-toggle"
      assert attribute(doc, "#term-root-more", "phx-click") == "custom-window"
    end

    test "a collection larger than the window offers to page in the rest" do
      doc = render_term(Enum.to_list(1..60), state: open([[]]))

      assert count(doc, "li") == 50
      assert text(doc, "#term-root-more") == "+10 more"
      assert attribute(doc, "#term-root-more", "phx-value-path") == ""
    end

    test "nothing is offered once every child is rendered" do
      doc =
        render_term(Enum.to_list(1..60),
          state: %State{open: MapSet.new([[]]), windows: %{[] => 100}}
        )

      assert count(doc, "li") == 60
      assert count(doc, "#term-root-more") == 0
    end

    test "a closed collection offers nothing to page in" do
      doc = render_term(Enum.to_list(1..60), state: open([]))

      assert count(doc, "#term-root-more") == 0
    end

    test "segment kinds become syntax colours" do
      doc = render_term(%{n: 1, s: "x", a: :b, t: true}, state: open([[]]))

      assert text(doc, "span.text-code-number") == "1"
      assert text(doc, "span.text-code-string") == "\"x\""
      assert text(doc, "span.text-code-special") == "true"
      assert texts(doc, "#term-0 span.text-code-atom") == ["a:", ":b"]
    end

    test "a truncation marker is rendered muted" do
      doc = render_term([:"$voyager_truncated"], state: open([[]]))

      assert text(doc, "span.text-code-punct.opacity-70") =~ "truncated"
    end

    test "a collection cut short on the remote node is flagged while still collapsed" do
      doc = render_term([1, :"$voyager_truncated"], state: open([]))

      assert attribute(doc, "#term-root-truncated", "class") =~ "text-warning"

      assert attribute(doc, "#term-root-truncated", "data-tooltip-target") ==
               "#term-root-truncated-tip"
    end

    test "an intact collection is not flagged" do
      assert count(render_term([1, 2], state: open([])), "#term-root-truncated") == 0
    end

    test "the inspector id namespaces every node id" do
      doc = render_term([1], id: "other", state: open([[]]))

      assert count(doc, "#other-root-toggle") == 1
      assert count(doc, "li#other-0") == 1
      assert attribute(doc, "#other-root-toggle", "phx-value-id") == "other"
    end

    test "extra classes are merged onto the root" do
      doc = render_term(42, class: "h-full")

      assert attribute(doc, "#term", "class") =~ "h-full"
      assert attribute(doc, "#term", "class") =~ "font-mono"
    end
  end
end
