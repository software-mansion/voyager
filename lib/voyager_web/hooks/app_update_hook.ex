defmodule VoyagerWeb.Hooks.AppUpdateHook do
  @moduledoc """
  LiveView hook that keeps `@app_update` in sync with `Voyager.Services.AppUpdater`
  and handles the `"install-app-update"`, `"dismiss-app-update"` and
  `"check-app-update"` events from the update modal and the settings page.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Services.AppUpdater

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, AppUpdater.topic())
    end

    socket =
      socket
      |> assign(:app_update, AppUpdater.current())
      |> assign(:app_update_supported?, AppUpdater.supported?())
      |> attach_hook(:app_update, :handle_info, &handle_app_update/2)
      |> attach_hook(:app_update_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_app_update({:app_update, update}, socket) do
    {:halt, assign(socket, :app_update, update)}
  end

  defp handle_app_update(_message, socket), do: {:cont, socket}

  defp handle_event("install-app-update", _params, socket) do
    AppUpdater.install()
    {:halt, socket}
  end

  defp handle_event("dismiss-app-update", _params, socket) do
    AppUpdater.dismiss()
    {:halt, socket}
  end

  defp handle_event("check-app-update", _params, socket) do
    AppUpdater.check()
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
