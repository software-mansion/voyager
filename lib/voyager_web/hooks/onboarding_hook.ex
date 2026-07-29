defmodule VoyagerWeb.Hooks.OnboardingHook do
  @moduledoc """
  LiveView hook that shows the first-launch telemetry/terms notice until the
  user dismisses it, persisting acceptance via `Voyager.Settings`.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Settings

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:show_onboarding?, not Settings.get(:terms_accepted, false))
      |> attach_hook(:dismiss_onboarding, :handle_event, &handle_dismiss/3)

    {:cont, socket}
  end

  defp handle_dismiss("dismiss-onboarding", _params, socket) do
    Settings.put(:terms_accepted, true)
    {:halt, assign(socket, :show_onboarding?, false)}
  end

  defp handle_dismiss(_event, _params, socket), do: {:cont, socket}
end
