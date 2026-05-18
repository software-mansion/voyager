defmodule Voyager.Connector do
  @moduledoc """
  Behaviour for establishing connections to remote BEAM nodes.
  """

  @callback connect(node_name :: String.t(), cookie :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback disconnect(node :: atom()) :: :ok
end
