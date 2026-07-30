defmodule VoyagerWeb.ConnectLive.SecretVisibility do
  @moduledoc """
  Shared show/hide behaviour for secret fields (cookies, passwords).

  Attaches a `:handle_event` hook that toggles a per-key `shown?` flag, so
  LiveComponents rendering `VoyagerWeb.ConnectComponents.secret_field/1` don't
  need to hand-write a `toggle_x` event for every secret field.
  """

  import Phoenix.Component

  import Phoenix.LiveView, only: [attach_hook: 4]

  @doc "Assigns the shared visibility set and attaches the toggle hook."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> assign(:secret_visibility, MapSet.new())
    |> attach_hook(:secret_visibility, :handle_event, &handle_event/3)
  end

  @doc "Hides every secret field, e.g. after loading a different connection."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket), do: assign(socket, :secret_visibility, MapSet.new())

  @doc "Whether the field identified by `key` is currently shown."
  @spec shown?(MapSet.t(), String.t()) :: boolean()
  def shown?(visibility, key), do: MapSet.member?(visibility, key)

  defp handle_event("toggle_secret_visibility", %{"key" => key}, socket) do
    {:halt, update(socket, :secret_visibility, &toggle(&1, key))}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp toggle(visibility, key) do
    if MapSet.member?(visibility, key) do
      MapSet.delete(visibility, key)
    else
      MapSet.put(visibility, key)
    end
  end
end
