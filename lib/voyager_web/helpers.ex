defmodule VoyagerWeb.Helpers do
  @moduledoc false

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
end
