defmodule Voyager.MCP do
  @moduledoc """
  MCP (Model Context Protocol) integration for Voyager.
  """

  use Supervisor

  alias Voyager.MCP.EndpointManager
  alias Voyager.MCP.Server

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    config = Application.get_env(:voyager, __MODULE__, [])
    opts = Keyword.merge(config, opts)

    if Keyword.get(opts, :enabled, true) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc """
  Changes the MCP HTTP listen port at runtime.

  Stops the current listener and starts a new one on the given port.
  Returns `:ok` on success or `{:error, reason}` if the port could not be bound.
  """
  @spec set_port(pos_integer()) :: :ok | {:error, term()}
  defdelegate set_port(port), to: EndpointManager

  @impl Supervisor
  def init(opts) do
    # `:one_for_all`: the three children form one logical MCP unit.
    # `EndpointManager` depends on both the `DynamicSupervisor` (which owns the
    # Bandit listener pid) and `Server` (the listener's Router forwards to it)
    # Restarting all three together keeps them consistent
    children = [
      {DynamicSupervisor, name: Voyager.MCP.DynamicSupervisor, strategy: :one_for_one},
      {EndpointManager, Keyword.get(opts, :endpoint, [])},
      {Server, transport: {:streamable_http, start: true}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
