defmodule VoyagerWeb.Hooks.OnboardingHook do
  @moduledoc """
  LiveView hook that shows the first-launch telemetry/terms notice until the
  user dismisses it, persisting acceptance via `Voyager.Telemetry.accept_terms/0`.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Settings
  alias Voyager.Telemetry

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:show_onboarding?, not Settings.get(:terms_accepted, false))
      |> attach_hook(:dismiss_onboarding, :handle_event, &handle_dismiss/3)

    {:cont, socket}
  end

  defp handle_dismiss("dismiss-onboarding", _params, socket) do
    case Telemetry.accept_terms() do
      {:ok, _} ->
        {:halt, assign(socket, :show_onboarding?, false)}

      {:error, _} ->
        {:halt, put_flash(socket, :error, "Failed to save terms acceptance")}
    end
  end

  defp handle_dismiss(_event, _params, socket), do: {:cont, socket}
end
