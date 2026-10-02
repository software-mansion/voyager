defmodule VoyagerWeb.Hooks.SidebarHook do
  @moduledoc """
  Assigns `:sidebar_mode` (`"compact"`, `"full"`, or `nil` to let the viewport
  decide) from session storage and handles the sidebar toggle.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias VoyagerWeb.Utils.SessionStorage

  @modes ["compact", "full"]

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:sidebar_mode, valid_mode(SessionStorage.get(socket, "sidebar")))
      |> attach_hook(:sidebar, :handle_event, &handle_toggle/3)

    {:cont, socket}
  end

  defp handle_toggle("toggle_sidebar", params, socket) do
    {:halt, assign(socket, :sidebar_mode, valid_mode(params["mode"]))}
  end

  defp handle_toggle(_event, _params, socket), do: {:cont, socket}

  defp valid_mode(mode) when mode in @modes, do: mode
  defp valid_mode(_mode), do: nil
end
