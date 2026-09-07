defmodule VoyagerWeb.Helpers do
  @moduledoc false

  alias VoyagerWeb.Utils.URL

  @spec ok(term()) :: {:ok, term()}
  def ok(state), do: {:ok, state}

  @spec noreply(term()) :: {:noreply, term()}
  def noreply(state), do: {:noreply, state}

  @spec cont(term()) :: {:cont, term()}
  def cont(state), do: {:cont, state}

  @spec halt(term()) :: {:halt, term()}
  def halt(state), do: {:halt, state}

  @doc """
  Shows a flash message from a `Phoenix.LiveComponent`.

  `put_flash/3` only propagates to the client from a component when paired
  with `push_navigate/2` or `push_patch/2`. This sends the flash to the
  parent LiveView instead, where `VoyagerWeb.Hooks.FlashHook` picks it up
  (mounted by default for LiveViews that `use VoyagerWeb, :live_view`).
  """
  @spec push_flash(Phoenix.LiveView.Socket.t(), atom(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def push_flash(socket, kind, msg) do
    send(self(), {:push_flash, kind, msg})
    socket
  end

  @doc """
  Carries the sidebar mode from `current_url` onto `path`, so following an
  in-page link does not reset the user's sidebar choice.
  """
  @spec keep_sidebar(String.t(), String.t() | nil) :: String.t()
  def keep_sidebar(path, current_url) when is_binary(current_url) do
    case URL.get_query_param(current_url, "sidebar") do
      mode when mode in ["compact", "full"] -> URL.put_query_param(path, "sidebar", mode)
      _other -> path
    end
  end

  def keep_sidebar(path, _current_url), do: path
end
