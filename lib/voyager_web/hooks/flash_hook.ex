defmodule VoyagerWeb.Hooks.FlashHook do
  @moduledoc """
  LiveView hook that shows flash messages sent by LiveComponents via
  `VoyagerWeb.Helpers.push_flash/3`.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :push_flash, :handle_info, &handle_push_flash/2)}
  end

  defp handle_push_flash({:push_flash, kind, msg}, socket) do
    {:halt, put_flash(socket, kind, msg)}
  end

  defp handle_push_flash(_event, socket), do: {:cont, socket}
end
