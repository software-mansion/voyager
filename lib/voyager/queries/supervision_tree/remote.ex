defmodule Voyager.Queries.SupervisionTree.Remote do
  @moduledoc false

  @doc """
  Returns a hardcoded list of demo applications.

  Set `config :voyager, :mock_remote_error, :some_reason` to exercise the
  LiveView's error branch during development.
  """
  @spec list_applications(node()) :: {:ok, [{atom(), charlist(), charlist()}]} | {:error, term()}
  def list_applications(_node) do
    case Application.get_env(:voyager, :mock_remote_error) do
      nil ->
        {:ok,
         [
           {:demo_app, ~c"Demo Application", ~c"1.0.0"},
           {:another_app, ~c"Another Application", ~c"0.5.0"}
         ]}

      reason ->
        {:error, reason}
    end
  end
end
