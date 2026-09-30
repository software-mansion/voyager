defmodule Voyager.Test.FakeConnector do
  @moduledoc """
  `Voyager.NodeSession.Connector` for tests. `connect/3` returns `{:error, fail}`
  for a `:fail` opt, else connects to `:node` (default `Node.self()`);
  `disconnect/2` sends `{:connector_disconnect, node}` to `:test_pid`, and
  `{:fake_transport_down, ref}` for the `:ref` opt tears the session down.
  """
  @behaviour Voyager.NodeSession.Connector

  @impl true
  def name, do: :fake

  @impl true
  def connect(_node_name, _cookie, opts) do
    case Keyword.get(opts, :fail) do
      nil ->
        meta = %{test_pid: Keyword.fetch!(opts, :test_pid), ref: Keyword.get(opts, :ref)}
        {:ok, Keyword.get(opts, :node, Node.self()), meta}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def disconnect(node, meta) do
    send(meta.test_pid, {:connector_disconnect, node})
    :ok
  end

  @impl true
  def subscriptions, do: ["fake_connector_topic"]

  @impl true
  def teardown?({:fake_transport_down, ref}, %{ref: ref}), do: true
  def teardown?(_msg, _meta), do: false
end
