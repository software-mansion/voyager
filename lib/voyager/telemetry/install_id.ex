defmodule Voyager.Telemetry.InstallId do
  @moduledoc """
  Anonymous installation identifier attached to exported telemetry events.

  A random UUID is generated and persisted via `Voyager.Settings` during
  telemetry manager init (with lazy fallback on first `get/0`), so events from
  the same installation can be correlated without identifying the user.

  The value is cached in `:persistent_term` because `get/0` is called while
  building the payload for every exported event.
  """

  alias Voyager.Settings

  require Logger

  @cache_key {__MODULE__, :install_id}
  @setting_key :install_id

  @doc """
  Returns the installation id, generating and persisting one on first call.
  """
  @spec get() :: String.t()
  def get do
    :persistent_term.get(@cache_key, nil) || load_or_generate()
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    _ = :persistent_term.erase(@cache_key)
    :ok
  end

  defp load_or_generate do
    case Settings.get(@setting_key) do
      nil -> generate()
      install_id -> cache(install_id)
    end
  end

  defp generate do
    install_id = Ecto.UUID.generate()

    case Settings.put(@setting_key, install_id) do
      {:ok, _setting} ->
        cache(install_id)

      {:error, reason} ->
        Logger.warning("Failed to persist telemetry install id: #{inspect(reason)}")
        install_id
    end
  end

  defp cache(install_id) do
    :persistent_term.put(@cache_key, install_id)
    install_id
  end
end
