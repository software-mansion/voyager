defmodule Voyager.Language do
  @moduledoc """
  Behaviour for detecting and inspecting the primary BEAM language running on a remote node.
  """

  alias Voyager.RPC.ERPC

  @type app_entry :: {atom(), charlist(), charlist()}
  @type app_list :: [app_entry()]

  @doc "Returns a map of language-specific runtime info."
  @type info :: %{optional(atom()) => term()}

  @callback detect?(apps :: app_list()) :: boolean()
  @callback name() :: String.t()
  @callback info(node :: atom()) :: info()

  @doc """
  Fetches the version string of an OTP application from the remote node.
  """
  @spec app_vsn(atom(), atom()) :: String.t() | nil
  def app_vsn(node, app) do
    case ERPC.call(node, :application, :get_key, [app, :vsn], 5_000) do
      {:ok, {:ok, vsn}} -> List.to_string(vsn)
      _ -> nil
    end
  end
end
