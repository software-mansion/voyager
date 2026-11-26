defmodule Voyager.MCP.Tools.TraceFormTest do
  use ExUnit.Case, async: true

  alias Voyager.MCP.Tools.TraceForm
  alias Voyager.Services.Tracer.Config

  test "an unchanged form keeps the config, including what the form cannot show" do
    for attrs <- [
          %{processes: :existing, budget: 20_000, max_time_ms: 2_500},
          %{
            processes: :pids,
            pids: ["<0.1.0>", "<0.2.0>"],
            capture: :args,
            scope: :local,
            return_trace: true,
            max_events: 10,
            max_rate: 5
          },
          %{processes: :new, function: "_", arity: nil, max_time_ms: 60_000},
          %{module: "calendar", function: "is_leap_year", max_events: 1}
        ] do
      current = config(attrs)

      assert {:ok, accepted} =
               current |> TraceForm.defaults() |> TraceForm.config_attrs(current)

      assert apply_attrs(accepted) == current
    end
  end

  test "prefills limits above the form's caps at the caps" do
    current = config(%{max_events: 50_000, max_rate: 5_000})
    defaults = TraceForm.defaults(current)

    assert %{"max_events" => 10_000, "max_rate" => 1_000} = defaults

    assert {:ok, %{"max_events" => 10_000, "max_rate" => 1_000}} =
             TraceForm.config_attrs(defaults, current)
  end

  test "applies a changed time limit and a cleared process list" do
    current = config(%{processes: :existing, max_time_ms: 2_500})
    changed = %{TraceForm.defaults(current) | "max_seconds" => 5}
    assert {:ok, %{"max_time_ms" => 5_000}} = TraceForm.config_attrs(changed, current)

    current = config(%{processes: :pids, pids: ["<0.1.0>"]})
    cleared = %{TraceForm.defaults(current) | "pids" => ""}
    assert {:ok, %{"processes" => "all"}} = TraceForm.config_attrs(cleared, current)
  end

  test "refuses an answer that is not an object, or pids that are not a list of them" do
    for content <- [
          5,
          %{"function" => "Date", "pids" => ["<0.1.0>"]},
          %{"function" => "Date", "pids" => " , "},
          %{"function" => "Date", "pids" => 1}
        ] do
      assert {:error, message} = TraceForm.config_attrs(content)
      assert message =~ ~r/object|`pids`/
    end

    assert {:ok, %{"processes" => "pids", "pids" => ["<0.1.0>"]}} =
             TraceForm.config_attrs(%{
               "function" => "Date",
               "pids" => "<0.1.0>,",
               "max_events" => 1
             })
  end

  defp config(attrs) do
    %{
      module: "Elixir.Date",
      function: "leap_year?",
      arity: 1,
      processes: :all,
      max_time_ms: 5_000
    }
    |> Map.merge(attrs)
    |> apply_attrs()
  end

  defp apply_attrs(attrs) do
    {:ok, config} = attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate)
    config
  end
end
