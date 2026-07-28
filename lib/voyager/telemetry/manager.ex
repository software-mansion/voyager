defmodule Voyager.Telemetry.Manager do
  @moduledoc """
  GenServer that attaches a `:telemetry` handler on start and detaches on terminate.

  Options:
  - `:telemetry_handler` - The handler module to use. Can be one of:
    - `:export` (requires `:telemetry_config` with `:push_url` and `:api_key`)
    - `:logger`
    - `:noop`
  - `:telemetry_config` - A keyword list of configuration options for the handler.
    It must contain `:push_url` and `:api_key`.
  """

  use GenServer

  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Handler

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    handler_module = handler_module(opts)
    handler_config = handler_config(opts)

    _ = :telemetry.detach(Handler.handler_id())

    :ok =
      :telemetry.attach_many(
        Handler.handler_id(),
        Events.events(),
        &handler_module.handle_event/4,
        handler_config
      )

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(Handler.handler_id())
  end

  defp handler_module(opts) do
    handler = Keyword.fetch!(opts, :telemetry_handler)

    case handler do
      :export -> Voyager.Telemetry.Handler.Export
      :logger -> Voyager.Telemetry.Handler.Logger
      _ -> Voyager.Telemetry.Handler.Noop
    end
  end

  defp handler_config(opts) do
    opts
    |> Keyword.get(:telemetry_config, [])
    |> Keyword.take([:push_url, :api_key])
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> Enum.into(%{})
  end
end
