defmodule VoyagerWeb.Components.TracingComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Voyager.Services.Tracer.Config
  alias VoyagerWeb.Components.TracingComponents

  @config %Config{module: "Elixir.Date", function: "leap_year?", arity: 1, max_events: 1_000}

  defp changed(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tr.text-primary")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end)
  end

  test "config_table/1 highlights each changed parameter beside its old value" do
    html =
      render_component(&TracingComponents.config_table/1,
        config: %{@config | scope: :local, max_events: nil},
        previous: @config
      )

    assert changed(html) == ["Scope Global Local", "Max events 1,000 None"]
  end

  test "config_table/1 highlights nothing without a previous config" do
    assert render_component(&TracingComponents.config_table/1, config: @config) |> changed() == []
  end

  test "config_chips/1 summarises where, what and the limits" do
    config = %{
      @config
      | processes: :pids,
        pids: ["<0.1.0>", "<0.2.0>"],
        capture: :args,
        budget: 2_000,
        return_trace: true,
        max_rate: 500,
        max_time_ms: 90_000
    }

    assert TracingComponents.config_chips(config) == [
             {:where, "Where", "2 pids · global"},
             {:capture, "Capture", "Args ≤ 2,000 + returns"},
             {:stop_after, "Stop after", "1,000 events · 500/s · 90 s"}
           ]

    assert [{:where, "Where", "All processes · global"}, {:capture, "Capture", "Arity"}, _limits] =
             TracingComponents.config_chips(%{@config | processes: :all})

    assert {:capture, "Capture", "Arity + returns ≤ 2,000"} in TracingComponents.config_chips(%{
             @config
             | return_trace: true,
               budget: 2_000
           })
  end

  defp changes(assigns) do
    (&TracingComponents.config_changes/1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "config_changes/1 lists each changed parameter with its old value" do
    assert changes(config: %{@config | scope: :local, max_events: nil}, previous: @config) ==
             "Scope Global → Local · Max events 1,000 → None"
  end

  test "config_changes/1 lists a budget change that only bounds the traced returns" do
    previous = %{@config | return_trace: true, budget: 1_000}

    assert changes(config: %{previous | budget: 2_000}, previous: previous) ==
             "Returns Traced ≤ 1,000 → Traced ≤ 2,000"
  end

  test "config_changes/1 reports no changes for an identical previous config" do
    assert changes(config: @config, previous: @config) == "no changes"
  end

  test "config_changes/1 shows the traced function without a previous config" do
    assert changes(config: @config) == "Date.leap_year?/1"
  end
end
