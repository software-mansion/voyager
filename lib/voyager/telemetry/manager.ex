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

  alias Voyager.Settings
  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Handler

  @enabled_key {__MODULE__, :enabled}

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    handler_module = handler_module(opts)
    handler_config = handler_config(opts)

    # Cached in :persistent_term (rather than read from the DB on every
    # dispatch) since `handle_event/4` runs synchronously in the caller's
    # process for every telemetry event.
    :persistent_term.put(@enabled_key, Settings.get(:telemetry_enabled, true))

    _ = :telemetry.detach(Handler.handler_id())

    :ok =
      :telemetry.attach_many(
        Handler.handler_id(),
        Events.events(),
        &__MODULE__.handle_event/4,
        %{handler_module: handler_module, handler_config: handler_config}
      )

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(Handler.handler_id())
  end

  @doc "Returns whether telemetry event forwarding is currently enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    :persistent_term.get(@enabled_key, true)
  end

  @doc """
  Enables or disables telemetry event forwarding, persisting the choice via
  `Voyager.Settings` and updating the in-memory cache read by `handle_event/4`.

  Returns `{:error, :locked}` when `:telemetry_enabled` is set in application config.
  """
  @spec set_enabled(boolean()) ::
          {:ok, Voyager.Schemas.Setting.t()} | {:error, :locked} | {:error, Ecto.Changeset.t()}
  def set_enabled(enabled?) when is_boolean(enabled?) do
    case Settings.put(:telemetry_enabled, enabled?) do
      {:ok, _setting} = ok ->
        :persistent_term.put(@enabled_key, enabled?)
        ok

      error ->
        error
    end
  end

  @doc """
  Telemetry attach callback shared by every handler.

  Checks the cached `:telemetry_enabled` setting before forwarding the event,
  so users can disable telemetry from Settings without restarting the app.
  """
  def handle_event(event, measurements, metadata, %{
        handler_module: handler_module,
        handler_config: handler_config
      }) do
    if enabled?() do
      handler_module.handle_event(event, measurements, metadata, handler_config)
    else
      :ok
    end
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
