defmodule VoyagerWeb.Helpers do
  @moduledoc false

  use VoyagerWeb, :verified_routes

  alias Voyager.NodeSession.Session

  @spec ok(term()) :: {:ok, term()}
  def ok(state), do: {:ok, state}

  @spec noreply(term()) :: {:noreply, term()}
  def noreply(state), do: {:noreply, state}

  @spec cont(term()) :: {:cont, term()}
  def cont(state), do: {:cont, state}

  @spec halt(term()) :: {:halt, term()}
  def halt(state), do: {:halt, state}

  @doc """
  Connect page path for a session, UI mode (`:direct` | `:ssh`), or connector name.

  Direct (`:direct`, `:distribution`, or `nil`) is `/`. SSH (`:ssh`) is `/?mode=ssh`.
  """
  @spec connect_path(Session.t() | :direct | :ssh | :distribution | nil) :: String.t()
  def connect_path(%Session{connector: connector}), do: connect_path(connector.name())
  def connect_path(:ssh), do: ~p"/?#{[mode: "ssh"]}"
  def connect_path(mode) when mode in [:direct, :distribution, nil], do: ~p"/"
  def connect_path(_), do: ~p"/"

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
end
