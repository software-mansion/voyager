defmodule Voyager.MCP do
  @moduledoc """
  MCP (Model Context Protocol) integration for Voyager.

  Port and IP are configured through `Voyager.Settings`, not supervisor options.
  """

  use Supervisor

  alias Voyager.MCP.EndpointManager
  alias Voyager.MCP.Server

  @doc """
  Starts the MCP supervision tree, or returns `:ignore` when disabled.

  The only supported option is `:enabled`. When `false`, the tree is not started
  and the application supervisor treats this child as ignored.

  Runtime `opts` override application config:

      config :voyager, Voyager.MCP, enabled: false
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    enabled =
      Application.get_env(:voyager, __MODULE__, [])
      |> Keyword.merge(opts)
      |> Keyword.get(:enabled, true)

    if enabled do
      Supervisor.start_link(__MODULE__, [], name: __MODULE__)
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

  @doc """
  Returns MCP runtime info as a map: `:alive?` (is the listener up) and `:url`
  (the endpoint URL it is, or would be, reachable at).
  """
  @spec info() :: %{alive?: boolean(), url: String.t()}
  defdelegate info, to: EndpointManager

  @doc """
  Toggles the MCP listener on/off at runtime. Returns `{:ok, :running}` or
  `{:ok, :stopped}` reflecting the new state, or `{:error, reason}`.
  """
  @spec toggle() :: {:ok, :running | :stopped} | {:error, term()}
  defdelegate toggle, to: EndpointManager

  @impl Supervisor
  def init(_) do
    # `:one_for_all`: the three children form one logical MCP unit.
    # `EndpointManager` depends on both the `DynamicSupervisor` (which owns the
    # Bandit listener pid) and `Server` (the listener's Router forwards to it)
    # Restarting all three together keeps them consistent
    children = [
      {DynamicSupervisor, name: Voyager.MCP.DynamicSupervisor, strategy: :one_for_one},
      {Server, transport: {:streamable_http, start: true}},
      EndpointManager
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
