defmodule VoyagerWeb.ConnectLive.Recents do
  @moduledoc "Shared stream plumbing for the connect panels' recent/favourite lists."

  @type keys :: %{pinned: atom(), recent: atom(), has_pinned: atom(), has_recent: atom()}

  @doc """
  Splits `connections` into pinned/recent, resets both streams, and assigns the
  non-empty flags under the stream and assign names given in `keys`.
  """
  @spec reset(Phoenix.LiveView.Socket.t(), [struct()], keys()) :: Phoenix.LiveView.Socket.t()
  def reset(socket, connections, keys) do
    {pinned, recent} = Enum.split_with(connections, & &1.pinned)

    socket
    |> Phoenix.LiveView.stream(keys.pinned, pinned, reset: true)
    |> Phoenix.LiveView.stream(keys.recent, recent, reset: true)
    |> Phoenix.Component.assign(keys.has_pinned, pinned != [])
    |> Phoenix.Component.assign(keys.has_recent, recent != [])
  end
end
