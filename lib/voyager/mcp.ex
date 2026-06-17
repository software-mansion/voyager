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
  Returns the configured MCP HTTP port.
  """
  @spec port() :: pos_integer() | nil
  defdelegate port(), to: EndpointManager

  @doc """
  Changes the MCP HTTP listen port at runtime.

  Stops the current listener and starts a new one on the given port.
  Returns `:ok` on success or `{:error, reason}` if the port could not be bound.
  """
  @spec set_port(pos_integer()) :: :ok | {:error, term()}
  defdelegate set_port(port), to: EndpointManager

  @doc """
  Returns the MCP Streamable HTTP endpoint URL (e.g. `http://127.0.0.1:4040/mcp`).
  """
  @spec url() :: String.t() | nil
  defdelegate url(), to: EndpointManager

  @impl Supervisor
  def init(opts) do
    children = [
      {Server, transport: {:streamable_http, start: true}},
      {EndpointManager, Keyword.get(opts, :endpoint, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
