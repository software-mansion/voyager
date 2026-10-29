defmodule VoyagerWeb.Hooks.UrlHook do
  @moduledoc """
  Assigns `:current_url` to every LiveView on each `handle_params/3`, and
  `:can_go_back?` once on mount: whether this page was opened from another page
  of the app (`_live_referer`, or the HTTP `Referer` of a full page load) other
  than through a link marked with `without_back_arrow/1`.
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
    |> assign(:can_go_back?, can_go_back?(params, session, socket))
    |> attach_hook(:current_url, :handle_params, &track_url/3)
    |> cont()
  end

  defp track_url(_params, url, socket) do
    {:cont, assign(socket, :current_url, URL.to_relative(url))}
  end

  defp can_go_back?(%{@no_back_param => "root"}, _session, _socket), do: false

  defp can_go_back?(_params, session, socket) do
    connect_params = get_connect_params(socket) || %{}
    referer = connect_params["_live_referer"] || session["referer"]

    # A tab opened straight onto this page (e.g. middle-click) has a referer but no history.
    connect_params["_history_length"] != 1 and is_binary(referer) and
      URI.parse(referer).host == socket.host_uri.host
  end
end
