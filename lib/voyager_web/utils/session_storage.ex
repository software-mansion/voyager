defmodule VoyagerWeb.Utils.SessionStorage do
  @moduledoc """
  Per-tab UI settings kept in the browser's `sessionStorage`.

  `assets/js/session_storage.js` sends every stored value with each LiveView
  join, so `get/2` only works during a connected mount: the dead render has no
  connect params and always reads `nil`.
  """

  alias Phoenix.LiveView
  alias Phoenix.LiveView.JS

  @spec get(LiveView.Socket.t(), String.t()) :: String.t() | nil
  def get(socket, key) do
    case LiveView.get_connect_params(socket) do
      %{"session_storage" => %{^key => value}} when is_binary(value) -> value
      _other -> nil
    end
  end

  @spec put(JS.t(), String.t(), String.t()) :: JS.t()
  def put(js \\ %JS{}, key, value) do
    JS.dispatch(js, "voyager:session-storage:put", detail: %{key: key, value: value})
  end
end
