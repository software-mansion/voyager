defmodule Voyager.Telemetry.InstallId do
  @moduledoc """
  Anonymous installation identifier attached to exported telemetry events.

  A random UUID is generated the first time an event is exported and persisted
  via `Voyager.Settings`, so events from the same installation can be correlated
  without identifying the user.

  The value is cached in `:persistent_term` because `get/0` is called while
  building the payload for every exported event.
  """

  alias Voyager.Settings

  @cache_key {__MODULE__, :install_id}
  @setting_key :install_id

  @doc """
  Returns the installation id, generating and persisting one on first call.
  """
  @spec get() :: String.t()
  def get do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        install_id = Settings.get(@setting_key) || generate()
        :persistent_term.put(@cache_key, install_id)
        install_id

      install_id ->
        install_id
    end
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    _ = :persistent_term.erase(@cache_key)
    :ok
  end

  defp generate do
    install_id = Ecto.UUID.generate()
    _ = Settings.put(@setting_key, install_id)
    install_id
  end
end
