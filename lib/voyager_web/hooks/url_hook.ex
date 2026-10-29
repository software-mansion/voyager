defmodule VoyagerWeb.Hooks.UrlHook do
  @moduledoc """
  Assigns `:current_url` to every LiveView on each `handle_params/3`, and
  `:return_to` once on mount: the `return_to` param, or else the page a live
  navigation came from (`nil` after a full page load).
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import VoyagerWeb.Helpers, only: [cont: 1]

  alias VoyagerWeb.Utils.URL

  @no_back_param "nav"

  @doc """
  Marks `path` so the page it opens shows no back arrow. For links that are not
  a step forward: the sidebar, and the back arrow itself.
  """
  @spec without_back_arrow(String.t()) :: String.t()
  def without_back_arrow(path), do: URL.put_query_param(path, @no_back_param, "root")

  def on_mount(:default, :not_mounted_at_router, _session, socket), do: {:cont, socket}

  def on_mount(:default, params, _session, socket) do
    socket
    |> assign(:return_to, return_to(params, socket))
    |> attach_hook(:current_url, :handle_params, &track_url/3)
    |> cont()
  end

  defp track_url(_params, url, socket) do
    {:cont, assign(socket, :current_url, URL.to_relative(url))}
  end

  defp return_to(%{@no_back_param => "root"}, _socket), do: nil
  defp return_to(%{"return_to" => path}, _socket), do: safe_path(path)

  defp return_to(_params, socket) do
    case get_connect_params(socket) do
      %{"_live_referer" => url} when is_binary(url) -> url |> URL.to_relative() |> safe_path()
      _ -> nil
    end
  end

  defp safe_path(path) when is_binary(path) do
    with %URI{scheme: nil, host: nil, path: "/" <> _ = route_path} <- URI.parse(path),
         %{} <- Phoenix.Router.route_info(VoyagerWeb.Router, "GET", route_path, "") do
      path
    else
      _ -> nil
    end
  end

  defp safe_path(_path), do: nil
end
