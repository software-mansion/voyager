defmodule VoyagerWeb.ConnectLive.RecentConnections do
  use Phoenix.Component
  import Phoenix.LiveView

  def init(socket, opts) do
    config = %{
      queries: Keyword.fetch!(opts, :queries),
      actions: Keyword.fetch!(opts, :actions)
    }

    socket
    |> assign(:recents, config)
    |> attach_hook(:recent_connections, :handle_event, &handle_event/3)
    |> reset()
  end

  def reset(%{assigns: %{recents: %{queries: queries}}} = socket) do
    {pinned, recent} = Enum.split_with(queries.all(), & &1.pinned)

    socket
    |> assign(:pinned_connections, pinned)
    |> assign(:recent_connections, recent)
  end

  defp handle_event("pin", %{"id" => id}, socket) do
    socket.assigns.recents.actions.pin(String.to_integer(id))
    {:halt, reset(socket)}
  end

  defp handle_event("unpin", %{"id" => id}, socket) do
    socket.assigns.recents.actions.unpin(String.to_integer(id))
    {:halt, reset(socket)}
  end

  defp handle_event("delete_connection", %{"id" => id}, socket) do
    socket.assigns.recents.actions.delete(String.to_integer(id))
    {:halt, reset(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  attr :pinned_connections, :list, required: true
  attr :recent_connections, :list, required: true
  attr :disabled, :boolean, default: false
  attr :id_prefix, :string, default: ""
  slot :row, required: true

  def render(assigns) do
    ~H"""
    <div
      :if={@pinned_connections != []}
      class={["border-base-300 mt-7 border-t pt-5", @disabled && "pointer-events-none opacity-40"]}
    >
      <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
        Favourites
      </p>
      <ul id={"#{@id_prefix}pinned-connections"} class="-mx-2 flex flex-col gap-0.5">
        <li :for={conn <- @pinned_connections} class="list-none">
          {render_slot(@row, {conn, true})}
        </li>
      </ul>
    </div>

    <div
      :if={@recent_connections != []}
      class={[
        "border-base-300 border-t pt-5",
        if(@pinned_connections != [], do: "mt-3", else: "mt-7"),
        @disabled && "pointer-events-none opacity-40"
      ]}
    >
      <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
        Recent connections
      </p>
      <ul id={"#{@id_prefix}recent-connections"} class="-mx-2 flex flex-col gap-0.5">
        <li :for={conn <- @recent_connections} class="list-none">
          {render_slot(@row, {conn, false})}
        </li>
      </ul>
    </div>
    """
  end
end
