defmodule Voyager.NodeSession.Connector do
  @moduledoc """
   Behaviour for a `Voyager.NodeSession` connection strategy.
  """

  @typedoc "Connector-specific state stored alongside the session."
  @type meta :: map()

  @callback name() :: atom()

  @callback connect(node_name :: String.t(), cookie :: String.t(), opts :: keyword()) ::
              {:ok, node(), meta()} | {:error, term()}

  @callback disconnect(node(), meta()) :: :ok

  @doc """
  PubSub topics the session should subscribe to while connected.
  """
  @callback subscriptions() :: [String.t()]

  @doc """
  Whether an incoming process message means this connector's transport has
  already gone away. When it returns `true`, `NodeSession` drops the session
  without calling `disconnect/2`.
  """
  @callback teardown?(msg :: term(), meta()) :: boolean()
end
