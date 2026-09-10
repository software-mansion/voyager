defmodule VoyagerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.CoreComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  @options [{"pid", "PID", true}, {"status", "Status", false}, {"memory", "Memory", false}]

  defp multiselect(attrs \\ []) do
    render_component(
      &CoreComponents.multiselect/1,
      Keyword.merge(
        [id: "ms", name: "f[cols]", label: "Columns", options: @options, selected: ["status"]],
        attrs
      )
    )
  end

  describe "multiselect/1" do
    test "shows the label and how many options are selected" do
      html = multiselect()

      assert text(html, "#ms") =~ "Columns"
      assert text(html, "#ms span.font-mono") == "1"
      assert text(multiselect(selected: []), "#ms span.font-mono") == "0"
    end

    test "renders a checkbox per unlocked option, checked when selected" do
      html = multiselect()

      assert count(html, ~s|#ms-status-input[type="checkbox"][checked]|) == 1
      assert count(html, ~s|#ms-memory-input[type="checkbox"]|) == 1
      assert count(html, "#ms-memory-input[checked]") == 0
      assert attr(html, "#ms-memory-input", "name") == ["f[cols][]"]
      assert attr(html, "#ms-memory-input", "value") == ["memory"]
    end

    test "submits a locked option as a hidden field with no checkbox" do
      html = multiselect()

      assert count(html, ~s|input[type="hidden"][name="f[cols][]"][value="pid"]|) == 1
      assert count(html, "#ms-pid-input") == 0
      assert attr(html, "#ms-pid-option", "title") == ["Always shown"]
    end

    test "disabling it takes the trigger out of the tab order" do
      assert attr(multiselect(), "#ms", "tabindex") == ["0"]
      assert count(multiselect(), "#ms[aria-disabled]") == 0

      disabled = multiselect(disabled: true)
      assert attr(disabled, "#ms", "tabindex") == ["-1"]
      assert count(disabled, "#ms[aria-disabled]") == 1
    end
  end

  describe "translate_error/1" do
    test "interpolates the error's placeholders" do
      assert CoreComponents.translate_error(
               {"must be between %{min} and %{max}", min: 1, max: 30}
             ) ==
               "must be between 1 and 30"
    end

    test "leaves a message without placeholders alone" do
      assert CoreComponents.translate_error({"is required", []}) == "is required"
    end
  end
end
