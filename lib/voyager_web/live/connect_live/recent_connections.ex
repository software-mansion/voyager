defmodule VoyagerWeb.ConnectLive.RecentConnections do
  @moduledoc """
  Shared "recents & favourites" behaviour for the connect panels.

  Pairs a lifecycle hook (`init/1` attaches a `:handle_event` hook that owns the
  pin/unpin/delete/reset lifecycle) with a `render/1` function component that
  draws the favourites and recent-connections lists. Each panel injects its own
  queries/actions modules and supplies a `:row` slot for panel-specific markup.
  """

  use Phoenix.Component

  import Phoenix.LiveView

  @type keys :: %{
          pinned: atom(),
          recent: atom(),
          has_pinned: atom(),
          has_recent: atom()
        }

  @doc """
  Attaches the shared pin/unpin/delete hook and streams the initial lists.

  Options:
    * `:queries` — query module exposing `all/0` (required)
    * `:actions` — action module exposing `pin/1`, `unpin/1`, `delete/1` (required)
    * `:keys` — stream/assign key map, see `t:keys/0` (required)
  """
  @spec init(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def init(socket, opts) do
    config = %{
      queries: Keyword.fetch!(opts, :queries),
      actions: Keyword.fetch!(opts, :actions),
      keys: Keyword.fetch!(opts, :keys)
    }

    socket
    |> assign(:recents, config)
    |> attach_hook(:recent_connections, :handle_event, &handle_event/3)
    |> reset()
  end

  @doc "Refetches the connections and re-streams both lists."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(%{assigns: %{recents: %{queries: queries, keys: keys}}} = socket) do
    {pinned, recent} = Enum.split_with(queries.all(), & &1.pinned)

    socket
    |> stream(keys.pinned, pinned, reset: true)
    |> stream(keys.recent, recent, reset: true)
    |> assign(keys.has_pinned, pinned != [])
    |> assign(keys.has_recent, recent != [])
  end

  defp handle_event("pin", %{"id" => id}, socket) do
    int_id = String.to_integer(id)
    socket.assigns.recents.actions.pin(int_id)
    {:halt, reset(socket)}
  end

  defp handle_event("unpin", %{"id" => id}, socket) do
    int_id = String.to_integer(id)
    socket.assigns.recents.actions.unpin(int_id)
    {:halt, reset(socket)}
  end

  defp handle_event("delete_connection", %{"id" => id}, socket) do
    int_id = String.to_integer(id)
    socket.assigns.recents.actions.delete(int_id)
    {:halt, reset(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  attr :streams, :map, required: true, doc: "The LiveView `@streams` container"
  attr :keys, :map, required: true, doc: "Stream key map, see `t:keys/0`"
  attr :has_pinned, :boolean, required: true
  attr :has_recent, :boolean, required: true
  attr :dom_prefix, :string, default: "", doc: "Prefix keeping list DOM ids unique per panel"
  slot :row, required: true, doc: "Row markup, receives `{conn, pinned?}`"

  @doc "Renders the favourites and recent-connections lists."
  def render(assigns) do
    ~H"""
    <div :if={@has_pinned} class="border-base-300 mt-7 border-t pt-5">
      <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
        Favourites
      </p>
      <ul
        id={"#{@dom_prefix}pinned-connections"}
        phx-update="stream"
        class="-mx-2 flex flex-col gap-0.5"
      >
        <li :for={{id, conn} <- @streams[@keys.pinned]} id={id} class="list-none">
          {render_slot(@row, {conn, true})}
        </li>
      </ul>
    </div>

    <div
      :if={@has_recent}
      class={["border-base-300 border-t pt-5", if(@has_pinned, do: "mt-3", else: "mt-7")]}
    >
      <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
        Recent connections
      </p>
      <ul
        id={"#{@dom_prefix}recent-connections"}
        phx-update="stream"
        class="-mx-2 flex flex-col gap-0.5"
      >
        <li :for={{id, conn} <- @streams[@keys.recent]} id={id} class="list-none">
          {render_slot(@row, {conn, false})}
        </li>
      </ul>
    </div>
    """
  end
end
