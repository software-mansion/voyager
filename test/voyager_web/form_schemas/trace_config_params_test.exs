defmodule VoyagerWeb.FormSchemas.TraceConfigParamsTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Tracer.Config
  alias VoyagerWeb.FormSchemas.TraceConfigParams

  defp to_config(attrs, params \\ TraceConfigParams.from_config(nil)) do
    {:ok, params} =
      params
      |> TraceConfigParams.changeset(attrs)
      |> Ecto.Changeset.apply_action(:validate)

    TraceConfigParams.to_config(params)
  end

  defp errors(attrs) do
    nil
    |> TraceConfigParams.from_config()
    |> TraceConfigParams.changeset(Map.put_new(attrs, "module", "MyApp.Repo"))
    |> Ecto.Changeset.traverse_errors(&VoyagerWeb.CoreComponents.translate_error/1)
  end

  test "prefills from a config as typed, and gives the same config back" do
    config = %Config{
      module: "Elixir.MyApp.Repo",
      function: "_",
      processes: :pids,
      pids: ["<0.1.0>", "<0.2.0>"],
      capture: :args,
      scope: :local,
      return_trace: true,
      budget: 100,
      max_events: nil,
      max_rate: nil,
      max_time_ms: 60_000
    }

    params = TraceConfigParams.from_config(config)

    assert %TraceConfigParams{
             module: "MyApp.Repo",
             function: nil,
             pids: "<0.1.0>, <0.2.0>",
             max_events: nil,
             max_rate: nil,
             max_seconds: 60
           } = params

    assert to_config(%{}, params) == config

    assert %TraceConfigParams{module: ":lists"} =
             TraceConfigParams.from_config(%{config | module: "lists"})
  end

  test "keeps a cleared limit empty instead of the new session's default" do
    attrs = %{"module" => "Date", "max_events" => "5", "max_rate" => "", "max_seconds" => ""}

    assert %Config{max_events: 5, max_rate: nil, max_time_ms: nil} = to_config(attrs)
  end

  test "puts a time over the cap on the seconds field, in seconds" do
    assert %{max_seconds: ["must be less than or equal to 3600"]} =
             errors(%{"max_seconds" => "7200"})
  end

  test "drops the typed pids when another process set is picked" do
    attrs = %{"module" => "Date", "processes" => "all", "pids" => "<0.1.0>"}

    assert %Config{processes: :all, pids: []} = to_config(attrs)
  end

  test "refuses a module that is neither an Elixir nor an Erlang name" do
    assert %{module: ["must look like MyApp.Repo or :lists"]} = errors(%{"module" => "my app"})
  end

  test "turns the form into a config, from seconds, a pid list and an Elixir module" do
    attrs = %{
      "module" => "MyApp.Repo",
      "function" => "",
      "arity" => "",
      "processes" => "pids",
      "pids" => "<0.1.0>, <0.2.0>\n<0.3.0>",
      "max_seconds" => "30"
    }

    assert %Config{
             module: "Elixir.MyApp.Repo",
             function: "_",
             arity: nil,
             processes: :pids,
             pids: ["<0.1.0>", "<0.2.0>", "<0.3.0>"],
             capture: :arity,
             scope: :global,
             return_trace: false,
             budget: 5_000,
             max_events: 10_000,
             max_rate: 1_000,
             max_time_ms: 30_000
           } = to_config(attrs)
  end
end
