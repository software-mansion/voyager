defmodule Voyager.NodeSession.Connectors.Distribution do
  @moduledoc """
   Default `Voyager.NodeSession.Connector` — direct Erlang distribution via
   `Voyager.Services.NodeConnector`.
  """

  @behaviour Voyager.NodeSession.Connector

  alias Voyager.Services.NodeConnector

  @impl true
  def name, do: :distribution

  @impl true
  def connect(node_name, cookie, opts) do
    case NodeConnector.connect(node_name, cookie, opts) do
      {:ok, node} -> {:ok, node, %{}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def disconnect(node, _meta), do: NodeConnector.disconnect(node)

  @impl true
  def subscriptions, do: []

  @impl true
  def teardown?(_msg, _meta), do: false
end
