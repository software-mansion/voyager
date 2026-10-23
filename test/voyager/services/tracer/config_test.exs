defmodule Voyager.Services.Tracer.ConfigTest do
  use ExUnit.Case, async: true

  import Voyager.DataCase, only: [errors_on: 1]

  alias Voyager.Services.Tracer.Config

  @valid %{
    module: "Elixir.Date",
    function: "leap_year?",
    arity: 1,
    pids: ["<0.1.0>"],
    max_events: 10
  }

  test "builds the agent's spec and limits" do
    assert {:ok, config} = apply_attrs(@valid)

    assert {%{
              module: "Elixir.Date",
              function: "leap_year?",
              arity: 1,
              processes: [pid],
              capture: :arity,
              scope: :global,
              return_trace: false,
              match_spec: :undefined
            }, %{budget: 5_000, max_events: 10} = limits} = Config.to_agent(config, [self()])

    assert pid == self()
    refute Map.has_key?(limits, :max_rate)
  end

  test "turns empty function and arity into agent wildcards" do
    assert {:ok, config} = apply_attrs(%{@valid | function: "_", arity: nil})
    assert {%{function: :_, arity: :_}, _limits} = Config.to_agent(config, [self()])
  end

  test "requires an empty arity with a wildcard function" do
    assert %{arity: [_]} = errors(%{@valid | function: "_"})
  end

  test "requires at least one limit" do
    assert %{max_events: [_]} = errors(Map.delete(@valid, :max_events))
  end

  test "caps the time limit and the budget" do
    assert %{max_time_ms: [_], budget: [_]} =
             errors(Map.merge(@valid, %{max_time_ms: 3_600_001, budget: 100_001}))
  end

  test "requires valid pids when tracing selected processes" do
    assert %{pids: [_]} = errors(%{@valid | pids: []})
    assert %{pids: [_]} = errors(%{@valid | pids: ["not a pid"]})
    assert %{pids: [_]} = errors(%{@valid | pids: [nil]})

    assert {:ok, _config} =
             apply_attrs(Map.merge(@valid, %{pids: [], processes: :all}))
  end

  test "refuses a hot module on all processes but not on selected pids" do
    assert %{module: [_]} = errors(Map.merge(@valid, %{module: "lists", processes: "new"}))
    assert %{module: [_]} = errors(Map.merge(@valid, %{module: "prim_file", processes: "all"}))
    assert {:ok, _config} = apply_attrs(%{@valid | module: "lists"})
  end

  test "always refuses the trace and agent modules" do
    assert %{module: [_]} = errors(%{@valid | module: "trace"})
    assert %{module: [_]} = errors(%{@valid | module: Atom.to_string(Voyager.Agent.module())})
  end

  defp apply_attrs(attrs),
    do: attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate)

  defp errors(attrs), do: attrs |> Config.changeset() |> errors_on()
end
