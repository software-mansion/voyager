defmodule VoyagerWeb.Hooks.PidFormatHook do
  @moduledoc """
  LiveView hook that keeps `@pid_format` in sync with the persisted setting.

  LiveViews read the assign instead of calling `Settings.get/2` on every render.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Settings

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, Settings.topic(:pid_format))
    end

    socket =
      socket
      |> assign(:pid_format, Settings.get(:pid_format, :distribution))
      |> attach_hook(:pid_format, :handle_info, &handle_pid_format/2)

    {:cont, socket}
  end

  defp handle_pid_format({:setting_changed, :pid_format, format}, socket) do
    {:cont, assign(socket, :pid_format, normalize_pid_format(format))}
  end

  defp handle_pid_format(_event, socket), do: {:cont, socket}

  defp normalize_pid_format(format) when format in [:distribution, :local], do: format
  defp normalize_pid_format(_), do: :distribution
end
