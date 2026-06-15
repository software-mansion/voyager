defmodule Voyager.Services.SupervisionTree.Remote do
  @moduledoc """
  Currently mock-only. Set `config :voyager, :mock_remote_error, :some_reason`
  to exercise the LiveView's error branch during development.
  """

  @type entry :: {atom(), charlist(), charlist()}

  @doc """
  Returns the list of OTP applications running on `node`.
  """
  @spec list_applications(node()) :: {:ok, [entry()]} | {:error, term()}
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
