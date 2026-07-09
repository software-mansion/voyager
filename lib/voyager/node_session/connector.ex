defmodule Voyager.NodeSession.Connector do
  @moduledoc """
  Behaviour for a `Voyager.NodeSession` connection strategy.

  A connector knows how to establish and tear down one kind of connection to a
  remote BEAM node. `NodeSession` stays agnostic: it stores the connector module
  plus an opaque `meta` map the connector returns, and delegates all
  transport-specific work back to the module.

  This is the seam that keeps optional transports (e.g. SSH tunnelling) out of
  the core session process — a transport is one module implementing this
  behaviour, wired in only by whoever calls `NodeSession.connect_via/4`.
  """

  @typedoc "Opaque, connector-specific state stored alongside the session."
  @type meta :: map()

  @doc "Short identifier for the transport, used in telemetry metadata."
  @callback name() :: atom()

  @doc """
  Establishes the connection. On success returns the connected node atom and an
  opaque `meta` map handed back to `disconnect/2` and `teardown?/2`.
  """
  @callback connect(node_name :: String.t(), cookie :: String.t(), opts :: keyword()) ::
              {:ok, node(), meta()} | {:error, term()}

  @doc "Tears down transport resources for a live connection."
  @callback disconnect(node(), meta()) :: :ok

  @doc """
  PubSub topics the session should subscribe to while connected, so the
  connector can signal that its transport died (see `teardown?/2`). Return `[]`
  when the transport needs no out-of-band teardown signal.
  """
  @callback subscriptions() :: [String.t()]

  @doc """
  Whether an incoming process message means this connector's transport has
  already gone away. When it returns `true`, `NodeSession` drops the session
  without calling `disconnect/2` (the transport is already gone).
  """
  @callback teardown?(msg :: term(), meta()) :: boolean()
end
