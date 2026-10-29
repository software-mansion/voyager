defmodule VoyagerWeb.Hooks.UrlHook do
  @moduledoc """
  Assigns `:current_url` and the validated `:return_to` param (or `nil`) to every
  LiveView on each `handle_params/3`.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import VoyagerWeb.Helpers, only: [cont: 1, keep_sidebar: 2]

  alias VoyagerWeb.Utils.URL

  def on_mount(:default, :not_mounted_at_router, _session, socket), do: {:cont, socket}

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :current_url, :handle_params, &track_url/3)}
  end

  defp track_url(_params, url, socket) do
    current_url = URL.to_relative(url)

    socket
    |> assign(:current_url, current_url)
    |> assign(:return_to, return_to(current_url))
    |> cont()
  end

  defp return_to(current_url) do
    with path when is_binary(path) <- URL.get_query_param(current_url, "return_to"),
         %URI{scheme: nil, host: nil, path: "/" <> _ = route_path} <- URI.parse(path),
         %{} <- Phoenix.Router.route_info(VoyagerWeb.Router, "GET", route_path, "") do
      keep_sidebar(path, current_url)
    else
      _ -> nil
    end
  end
end
