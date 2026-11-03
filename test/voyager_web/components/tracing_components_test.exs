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
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
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
end
