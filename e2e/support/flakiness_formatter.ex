defmodule Voyager.E2E.FlakinessFormatter do
  @moduledoc """
  An ExUnit formatter for `e2e/bench-flakiness.sh`: appends one JSON line per
  finished test (skipped and excluded tests aside) to the file in
  `FLAKINESS_LOG`, tagged with `FLAKINESS_ATTEMPT`. Run it next to
  `ExUnit.CLIFormatter`.
  """
  use GenServer

  alias Playwright.Test.Project

  @impl true
  def init(_opts) do
    {:ok,
     %{
       path: System.fetch_env!("FLAKINESS_LOG"),
       attempt: System.get_env("FLAKINESS_ATTEMPT", "1")
     }}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: state} = test}, config) do
    case status(state) do
      nil ->
        :ok

      status ->
        File.write!(config.path, JSON.encode!(entry(test, status, config.attempt)) <> "\n", [
          :append
        ])
    end

    {:noreply, config}
  end

  def handle_cast(_event, config), do: {:noreply, config}

  defp status(nil), do: "passed"
  defp status({:skipped, _reason}), do: nil
  defp status({:excluded, _reason}), do: nil
  defp status(_failed), do: "failed"

  defp entry(test, status, attempt) do
    %{test: label(test), status: status, attempt: String.to_integer(attempt)}
  end

  # "Module test name [project]", as the JS report named a test with its project.
  defp label(%ExUnit.Test{module: module, name: name, parameters: parameters}) do
    projects = for {_key, %Project{} = project} <- parameters, do: Project.title(project)
    "#{inspect(module)} #{name} [#{Enum.join(projects)}]"
  end
end
