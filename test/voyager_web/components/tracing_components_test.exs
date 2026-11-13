defmodule VoyagerWeb.Components.TracingComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
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

  test "tone/1 and reason_tone/1 group stop reasons by outcome" do
    base = %Session{id: 1, origin: :ui, created_at: ~U[2026-01-01 00:00:00Z]}

    assert TracingComponents.tone(%{base | status: :running}) == :running
    assert TracingComponents.tone(%{base | status: :idle}) == :open

    for reason <- [:stopped, :disconnected] do
      assert TracingComponents.tone(%{base | status: :stopped, stop_reason: reason}) == :open
    end

    for reason <- [
          :node_down,
          :event_limit,
          :rate_limit,
          :time_limit,
          :mailbox_limit,
          :storage_limit
        ] do
      assert TracingComponents.tone(%{base | status: :stopped, stop_reason: reason}) == :warning
    end

    for reason <- [:interrupted, :write_failed, {:tracer_down, :killed}] do
      assert TracingComponents.tone(%{base | status: :stopped, stop_reason: reason}) == :error
    end
  end

  test "other_node?/2 marks configured sessions from a different node without overriding tone" do
    session = %Session{
      id: 1,
      origin: :ui,
      created_at: ~U[2026-01-01 00:00:00Z],
      node: :other@localhost,
      status: :stopped,
      stop_reason: :interrupted
    }

    assert TracingComponents.tone(session) == :error
    assert TracingComponents.other_node?(session, :demo@localhost)
    refute TracingComponents.other_node?(session, :other@localhost)
    refute TracingComponents.other_node?(session, nil)
    refute TracingComponents.other_node?(%{session | node: nil}, :demo@localhost)
  end
end
