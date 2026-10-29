defmodule VoyagerWeb.Hooks.UrlHook do
  @moduledoc """
  Assigns `:current_url` to every LiveView on each `handle_params/3`, and once on
  mount:

    * `:return_to` - the validated `return_to` param, or `nil`
    * `:can_go_back?` - whether this page was opened from another page of the
      app (`_live_referer`, or the HTTP `Referer` of a full page load) other than
      through a link marked with `without_back_arrow/1`
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import VoyagerWeb.Helpers, only: [cont: 1]

  alias VoyagerWeb.Utils.URL

  @no_back_param "nav"

  @doc """
  Marks `path` so the page it opens shows no back arrow, for links that start a
  new trail such as the sidebar.
  """
  @spec without_back_arrow(String.t()) :: String.t()
  def without_back_arrow(path), do: URL.put_query_param(path, @no_back_param, "root")

  @doc """
  `live_session` session MFA: carries the full page load's `Referer` header into
  both the static and the connected mount, so they agree on the back arrow.
  """
  @spec referer_session(Plug.Conn.t()) :: %{optional(String.t()) => String.t()}
  def referer_session(conn) do
    case Plug.Conn.get_req_header(conn, "referer") do
      [referer | _] -> %{"referer" => referer}
      [] -> %{}
    end
  end

  def on_mount(:default, :not_mounted_at_router, _session, socket), do: {:cont, socket}

  def on_mount(:default, params, session, socket) do
    socket
    |> assign(:return_to, safe_path(params["return_to"]))
    |> assign(:can_go_back?, can_go_back?(params, session, socket))
    |> attach_hook(:current_url, :handle_params, &track_url/3)
    |> cont()
  end

  defp track_url(_params, url, socket) do
    {:cont, assign(socket, :current_url, URL.to_relative(url))}
  end

  defp can_go_back?(%{@no_back_param => "root"}, _session, _socket), do: false

  defp can_go_back?(_params, session, socket) do
    referer = (get_connect_params(socket) || %{})["_live_referer"] || session["referer"]
    is_binary(referer) and URI.parse(referer).host == socket.host_uri.host
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
