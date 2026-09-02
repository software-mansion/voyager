defmodule VoyagerWeb.Components.ProcessComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.ProcessListControls

  # Tooltip content is portaled inside a `<template>`, which the parser keeps
  # out of the tree; unwrap it so the tip's content is queryable.
  defp query(html, selector) do
    html
    |> String.replace("<template", "<div data-template")
    |> String.replace("</template>", "</div>")
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  @row %{
    pid: nil,
    registered_name: :probe,
    initial_call: {:gen_server, :init_it, 6},
    current_function: nil,
    memory: 2_048,
    reductions: 1_500,
    message_queue_len: 3,
    status: :waiting,
    priority: :normal
  }

  defp cell(key, overrides \\ %{}) do
    render_component(&ProcessComponents.cell/1,
      column: %{key: key},
      row: Map.merge(%{@row | pid: self()}, overrides),
      row_id: "r",
      pid_href: "/p"
    )
  end

  defp controls(attrs \\ []) do
    form = to_form(ProcessListControls.changeset(ProcessListControls.default()), as: :controls)

    render_component(
      &ProcessComponents.controls/1,
      Keyword.merge([form: form, node_name: "demo@host", loading?: false], attrs)
    )
  end

  defp summary(round_trip_ms) do
    render_component(&ProcessComponents.scan_summary/1,
      id: "s",
      shown: 1,
      scanned: 2,
      round_trip_ms: round_trip_ms
    )
  end

  describe "columns/1" do
    test "keeps display order regardless of selection order" do
      assert Enum.map(ProcessComponents.columns([:memory, :pid]), & &1.key) == [:pid, :memory]
    end

    test "ignores unknown attributes" do
      assert ProcessComponents.columns([:nope]) == []
    end
  end

  describe "column_label/1" do
    test "uses the human label, falling back to the attribute name" do
      assert ProcessComponents.column_label(:message_queue_len) == "MsgQ"
      assert ProcessComponents.column_label(:whatever) == "whatever"
    end
  end

  describe "format_name/1 and format_mfa/1" do
    test "formats a registered name, the head of a name list, or a placeholder" do
      assert ProcessComponents.format_name(:probe) == ":probe"
      assert ProcessComponents.format_name([:first, :second]) == ":first"
      assert ProcessComponents.format_name(nil) == "—"
    end

    test "formats an mfa, a placeholder for nil, and inspects anything else" do
      assert ProcessComponents.format_mfa({:gen_server, :init_it, 6}) == ":gen_server.init_it/6"
      assert ProcessComponents.format_mfa(nil) == "—"
      assert ProcessComponents.format_mfa(:odd) == ":odd"
    end
  end

  describe "cell/1" do
    test "pid links to the details page and offers the pid to copy" do
      html = cell(:pid)
      pid = Processes.format_pid(self())

      assert attr(html, "a", "href") == ["/p"]
      assert text(html, "a") =~ pid
      assert text(html, "#r-pid-copy-text") == pid
      assert count(html, "#r-pid-copy") == 1
    end

    test "formats each value column with a stable id" do
      assert text(cell(:registered_name), "#r-name-copy-text") == ":probe"
      assert text(cell(:initial_call), "#r-initial-call-copy-text") == ":gen_server.init_it/6"
      assert text(cell(:memory), "#r-memory-copy-text") == Formatters.format_bytes(2_048)

      assert text(cell(:reductions), "#r-reductions-copy-text") ==
               Formatters.format_integer(1_500)

      assert text(cell(:status), "#r-status-copy-text") == "waiting"
      assert text(cell(:priority), "#r-priority-copy-text") == "normal"
    end

    test "a missing value explains the gap instead of offering it to copy" do
      html = cell(:current_function)

      assert text(html, ~s|[role="tooltip"]|) =~ "Not set"
      assert count(html, "#r-current-function-copy") == 0
    end

    test "highlights a non-empty message queue" do
      assert count(cell(:message_queue_len), "span.text-warning") == 1
      assert count(cell(:message_queue_len, %{message_queue_len: 0}), "span.text-warning") == 0
    end
  end

  describe "value_cell/1" do
    test "mutes secondary values" do
      muted = render_component(&ProcessComponents.value_cell/1, id: "v", value: "x", muted: true)
      plain = render_component(&ProcessComponents.value_cell/1, id: "v", value: "x")

      assert count(muted, ~s|span[class*="text-base-content/70"]|) >= 1
      assert count(plain, ~s|span.truncate[class*="text-base-content/70"]|) == 0
    end
  end

  describe "controls/1" do
    test "renders the search, limit, timeout and columns controls with their defaults" do
      html = controls()

      assert count(html, "#process-controls") == 1
      assert count(html, ~s|#controls_search[type="search"]|) == 1
      assert attr(html, "#controls_limit option[selected]", "value") == ["100"]
      assert attr(html, "#controls_timeout", "value") == ["5000"]
      assert count(html, "#process-controls-columns") == 1
    end

    test "locks the required columns and checks the default ones" do
      html = controls()

      for locked <- ProcessListControls.required_columns() do
        assert count(
                 html,
                 ~s|input[type="hidden"][name="controls[columns][]"][value="#{locked}"]|
               ) == 1

        assert count(html, "#process-controls-columns-#{locked}-input") == 0
      end

      assert count(html, "#process-controls-columns-registered_name-input[checked]") == 1
      assert count(html, "#process-controls-columns-status-input[checked]") == 0
      assert count(html, "#process-controls-columns-status-input") == 1
    end

    test "disables every control while a fetch runs" do
      html = controls(loading?: true)

      assert count(html, "fieldset[disabled]") == 1
      assert count(html, "#process-controls-columns[aria-disabled]") == 1
      assert count(controls(), "fieldset[disabled]") == 0
    end

    test "shows a field's error and marks its input" do
      {_controls, changeset} =
        ProcessListControls.apply(ProcessListControls.default(), %{"timeout" => "10"})

      html =
        render_component(&ProcessComponents.controls/1,
          form: to_form(changeset, as: :controls),
          node_name: "demo@host"
        )

      assert [class] = attr(html, "#controls_timeout", "class")
      assert class =~ "input-error"
      assert text(html, ".text-error") =~ "must be between"
    end

    test "names the node in the help text" do
      assert controls() =~ "demo@host"
    end
  end

  describe "scan_summary/1" do
    test "colours the round trip by how slow the fetch was" do
      bands = [
        {900, "text-base-content"},
        {1_000, "text-base-content"},
        {1_001, "text-warning"},
        {10_000, "text-error"}
      ]

      for {ms, class} <- bands, do: assert(summary(ms) =~ class)
    end

    test "omits the round trip when there is none" do
      refute summary(nil) =~ "ms"
    end
  end
end
