defmodule VoyagerWeb.Hooks.UrlHook do
  @moduledoc """
  Assigns `:current_url` to every LiveView on each `handle_params/3`.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias VoyagerWeb.Utils.URL

  def on_mount(:default, :not_mounted_at_router, _session, socket), do: {:cont, socket}

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :current_url, :handle_params, &track_url/3)}
  end

  defp track_url(_params, url, socket) do
    {:cont, assign(socket, :current_url, URL.to_relative(url))}
  end
end
